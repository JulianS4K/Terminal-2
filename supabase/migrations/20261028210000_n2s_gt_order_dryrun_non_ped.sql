-- Migration 20261028210000 · level:secondary-sales · lane:D7 · writes:n2s_gt_order_dryrun_capture · reads:n2s_cover_queue,n2s_items · pre:20261021223000
--
-- GoTickets auto-buy DRY RUN: non-PED orders only.
--
-- Operator direction 2026-10-28: "only dry run on non-ped". PED (Need2Buy)
-- orders are n2s_items rows with a negative n2s_id and status 'n2b' /
-- 'n2b_closed'; they are no longer captured at all (not even as 'skip').
-- Everything else is the 20261021180000 body unchanged.
--
-- Still nothing is sent: the capture only writes n2s_gt_order_dryrun rows.
--
-- rollback: re-create n2s_gt_order_dryrun_capture() without the two PED
-- predicates in the loop's WHERE (20261021180000).

CREATE OR REPLACE FUNCTION public.n2s_gt_order_dryrun_capture(p_per_order_cap numeric DEFAULT 2000, p_daily_cap numeric DEFAULT 15000, p_gates integer[] DEFAULT '{1,2}'::integer[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_reasons text[];
  v_day_start timestamptz :=
    date_trunc('day', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York';
  v_spend numeric;
  v_view text;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT q.*, i.is_terminal, i.event_dt, i.timer_expires_at, i.timer_expired, i.alert_at,
           ge.gt_event_id,
           g.all_in_price AS live_price, g.quantity AS live_qty, g.splits AS live_splits,
           g.pulled_at AS live_pulled_at, g.notes AS live_notes
      FROM public.n2s_cover_queue q
      JOIN public.n2s_items i ON i.n2s_id = q.n2s_id
      LEFT JOIN LATERAL (SELECT e.gt_event_id FROM public.gotickets_event e
                          WHERE e.tevo_event_id = q.tevo_event_id LIMIT 1) ge ON true
      LEFT JOIN LATERAL (SELECT c.* FROM public.n2s_gt_current c
                          WHERE c.tevo_event_id = q.tevo_event_id
                            AND c.gt_listing_id::text = q.sub_listing_id
                          ORDER BY c.pulled_at DESC LIMIT 1) g ON true
     WHERE q.sub_source = 'gotickets'
       AND q.sub_listing_id IS NOT NULL
       AND q.sub_ea IS NOT NULL
       -- non-PED only (operator 2026-10-28)
       AND q.n2s_id > 0
       AND COALESCE(i.status, '') NOT IN ('n2b', 'n2b_closed')
       AND NOT EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
                        WHERE d.n2s_id = q.n2s_id
                          AND d.sub_listing_id = q.sub_listing_id
                          AND d.quoted_ea = q.sub_ea)
     ORDER BY q.fifo_position NULLS LAST, q.n2s_id
  LOOP
    v_reasons := '{}';
    v_view := CASE WHEN r.live_notes IS NULL THEN 'unknown'
                   ELSE public.n2s_view_of(r.live_notes, NULL) END;

    SELECT COALESCE(sum(d.quoted_total), 0) INTO v_spend
      FROM public.n2s_gt_order_dryrun d
     WHERE d.decision = 'would_buy' AND d.captured_at >= v_day_start;

    IF NOT (COALESCE(r.cover_gate, 0) = ANY (p_gates))  THEN v_reasons := array_append(v_reasons, 'gate_moves_buyer'); END IF;
    IF v_view = 'obstructed'                            THEN v_reasons := array_append(v_reasons, 'obstructed_view'); END IF;
    IF r.gt_event_id IS NULL                            THEN v_reasons := array_append(v_reasons, 'no_gt_event_id'); END IF;
    IF r.live_price IS NULL THEN
      v_reasons := array_append(v_reasons, 'listing_gone');
    ELSE
      IF r.live_price > r.sub_ea                        THEN v_reasons := array_append(v_reasons, 'price_up'); END IF;
      IF COALESCE(r.live_qty, 0) < COALESCE(r.sub_qty, 1) THEN v_reasons := array_append(v_reasons, 'qty_unavailable'); END IF;
      IF cardinality(r.live_splits) > 0
         AND NOT (COALESCE(r.sub_qty, 1) = ANY (r.live_splits)) THEN v_reasons := array_append(v_reasons, 'split_not_allowed'); END IF;
    END IF;
    IF COALESCE(r.is_terminal, false)                   THEN v_reasons := array_append(v_reasons, 'order_closed'); END IF;
    IF NOT public.n2s_timer_open(r.timer_expires_at, r.timer_expired, r.alert_at)
                                                        THEN v_reasons := array_append(v_reasons, 'timer_closed'); END IF;
    IF NOT public.n2s_event_live(r.event_dt, r.tevo_event_id, interval '0')
                                                        THEN v_reasons := array_append(v_reasons, 'event_started'); END IF;
    IF COALESCE(r.sub_total, 0) > p_per_order_cap       THEN v_reasons := array_append(v_reasons, 'over_order_cap'); END IF;
    IF v_spend + COALESCE(r.sub_total, 0) > p_daily_cap THEN v_reasons := array_append(v_reasons, 'over_daily_cap'); END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
                WHERE d.n2s_id = r.n2s_id AND d.decision = 'would_buy')
                                                        THEN v_reasons := array_append(v_reasons, 'already_bought'); END IF;

    INSERT INTO public.n2s_gt_order_dryrun (
      n2s_id, order_number, s4k_source, event_name, event_date, tevo_event_id,
      gt_event_id, sold_section, sold_row, sold_qty, sold_ea,
      sub_listing_id, sub_section, sub_row, sub_qty, quoted_ea, quoted_total,
      cover_cost, cover_gate, cover_label,
      live_price_ea, live_qty, live_splits, live_pulled_at, sub_view,
      decision, skip_reasons, per_order_cap, daily_cap, day_spend_before, payload)
    VALUES (
      r.n2s_id, r.order_number, r.s4k_source, r.event_name, r.event_date, r.tevo_event_id,
      r.gt_event_id, r.section, r.order_row, r.quantity, r.sold_ea,
      r.sub_listing_id, r.sub_section, r.sub_row, r.sub_qty, r.sub_ea, r.sub_total,
      r.cover_cost, r.cover_gate, r.cover_label,
      r.live_price, r.live_qty, r.live_splits, r.live_pulled_at, v_view,
      CASE WHEN cardinality(v_reasons) = 0 THEN 'would_buy' ELSE 'skip' END,
      v_reasons, p_per_order_cap, p_daily_cap, v_spend,
      jsonb_build_object(
        '_dry_run',           true,
        '_not_sent',          'Dry run only. Nothing calls GoTickets (20261021180000).',
        'endpoint',           'POST https://gotickets.com/rest/pro/api/orders',
        'eventId',            r.gt_event_id,
        'listingId',          r.sub_listing_id,
        'quantity',           r.sub_qty,
        'expectedTotal',      NULL,
        'paymentMethodToken', NULL,
        'deliveryMethodId',   NULL,
        'emailAddress',       NULL,
        'phoneNumber',        NULL,
        'billingAddress',     NULL,
        'recipient',          NULL,
        'buyerNotes',         'N2S cover for ' || COALESCE(r.s4k_source, '?') || ' order ' || r.order_number,
        '_reference',         jsonb_build_object(
            'quoted_ea', r.sub_ea, 'quoted_total', r.sub_total,
            'cover_cost', r.cover_cost, 'buy_url', r.buy_url)))
    ON CONFLICT ON CONSTRAINT n2s_gt_order_dryrun_once DO NOTHING;

    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_gt_order_dryrun_capture(numeric, numeric, integer[]) FROM PUBLIC, anon;
