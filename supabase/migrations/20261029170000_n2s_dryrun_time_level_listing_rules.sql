-- Migration 20261029170000 · level:secondary-sales · lane:D7 · writes:n2s_gt_order_dryrun,n2s_section_level,n2s_dryrun_extra_reasons,n2s_gt_order_dryrun_capture,n2s_evo_order_dryrun_capture · reads:n2s_gt_order_dryrun · pre:20261029020000
--
-- Auto-buy DRY RUN: three rules a live buyer needs (operator 2026-10-29:
-- "assume it could take a few mins to accept the order we placed on gotix or
-- evo, add the rules you need").
--
--  1. not_enough_time — skip unless >= 6 minutes remain on the sale's timer.
--     Our purchase has to be accepted by the selling broker before we accept
--     the sale. Measured on our own EVO purchases (90 days, 71 orders, seller
--     Victory Live): accepted ones flip in 2–43 s (p50 4 s); the ones a seller
--     never accepts sit PENDING until EVO auto-rejects them at ~24–26 min
--     (9 orders, 1418–1552 s). So "a few minutes" of headroom: 5 min for the
--     seller + 1 min for our accept. GoTickets has no acceptance timestamp we
--     can read, so the same budget applies.
--  2. level_mismatch — when both the sold and the sub section name a level
--     (Floor, Loge, Lower, Upper, Mezz, Balcony, Club, …) the levels must
--     agree. Dry-run #21 "covered" Floor 6/B with Loge 6/B and logged a
--     $4,100 "profit". Bare numbers and "Section 205" carry no level and pass.
--  3. listing_taken — one listing can cover one order: skip when another
--     order already has a would_buy on the same sub listing (11 listings were
--     offered to several orders, one to 6).
--
-- New column seconds_left records the sale timer left at decision time.
-- Nothing is sent to any market.
--
-- rollback: re-apply 20261028213000 (GoTickets) and 20261028220000 (EVO)
-- capture bodies; DROP FUNCTION n2s_dryrun_extra_reasons, n2s_section_level;
-- the seconds_left column can stay.

ALTER TABLE public.n2s_gt_order_dryrun ADD COLUMN IF NOT EXISTS seconds_left integer;

CREATE OR REPLACE FUNCTION public.n2s_section_level(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE m WHEN 'mezzanine' THEN 'mezz' WHEN 'bleachers' THEN 'bleacher' ELSE m END
    FROM (SELECT (regexp_match(lower(COALESCE(p, '')),
            '\m(floor|field|court|loge|lower|upper|mezzanine|mezz|balcony|club|terrace|plaza|suite|box|orchestra|pavilion|bleachers|bleacher|grandstand|main)\M'))[1] AS m) x
$function$;

CREATE OR REPLACE FUNCTION public.n2s_dryrun_extra_reasons(p_n2s_id bigint, p_sub_source text, p_listing text,
                                                         p_section text, p_sub_section text, p_timer_expires_at timestamptz)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v text[] := '{}';
  a text := public.n2s_section_level(p_section);
  b text := public.n2s_section_level(p_sub_section);
BEGIN
  IF a IS NOT NULL AND b IS NOT NULL AND a <> b THEN
    v := array_append(v, 'level_mismatch');
  END IF;
  IF EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
              WHERE d.decision = 'would_buy' AND d.sub_source = p_sub_source
                AND d.sub_listing_id = p_listing AND d.n2s_id <> p_n2s_id) THEN
    v := array_append(v, 'listing_taken');
  END IF;
  IF p_timer_expires_at IS NOT NULL AND p_timer_expires_at - now() < interval '6 minutes' THEN
    v := array_append(v, 'not_enough_time');
  END IF;
  RETURN v;
END $function$;

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
       -- sold on a marketplace whose API token works (operator 2026-10-28)
       AND lower(COALESCE(q.s4k_source, '')) LIKE ANY (ARRAY['evo%', 'gotickets%', 'seatgeek%', 'vivid%'])
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
    -- 20261029170000: level mismatch, one listing per order, time budget for the seller to accept our buy
    v_reasons := v_reasons || public.n2s_dryrun_extra_reasons(r.n2s_id, 'gotickets', r.sub_listing_id,
                                                              r.section, r.sub_section, r.timer_expires_at);

    INSERT INTO public.n2s_gt_order_dryrun (
      n2s_id, order_number, s4k_source, event_name, event_date, tevo_event_id,
      gt_event_id, sold_section, sold_row, sold_qty, sold_ea,
      sub_listing_id, sub_section, sub_row, sub_qty, quoted_ea, quoted_total,
      cover_cost, cover_gate, cover_label,
      live_price_ea, live_qty, live_splits, live_pulled_at, sub_view,
      seconds_left, decision, skip_reasons, per_order_cap, daily_cap, day_spend_before, payload)
    VALUES (
      r.n2s_id, r.order_number, r.s4k_source, r.event_name, r.event_date, r.tevo_event_id,
      r.gt_event_id, r.section, r.order_row, r.quantity, r.sold_ea,
      r.sub_listing_id, r.sub_section, r.sub_row, r.sub_qty, r.sub_ea, r.sub_total,
      r.cover_cost, r.cover_gate, r.cover_label,
      r.live_price, r.live_qty, r.live_splits, r.live_pulled_at, v_view,
      GREATEST(0, extract(epoch FROM (r.timer_expires_at - now())))::int,
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

CREATE OR REPLACE FUNCTION public.n2s_evo_order_dryrun_capture(p_per_order_cap numeric DEFAULT 2000, p_daily_cap numeric DEFAULT 15000, p_gates integer[] DEFAULT '{1}'::integer[])
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
           e.retail_price AS live_price, e.quantity AS live_qty, e.splits AS live_splits,
           e.pulled_at AS live_pulled_at, e.public_notes AS live_notes, e.is_owned
      FROM public.n2s_cover_queue q
      JOIN public.n2s_items i ON i.n2s_id = q.n2s_id
      LEFT JOIN LATERAL (SELECT c.* FROM public.n2s_evo_current c
                          WHERE c.event_id = q.tevo_event_id
                            AND c.tevo_ticket_group_id::text = q.sub_listing_id
                          ORDER BY c.pulled_at DESC LIMIT 1) e ON true
     WHERE q.sub_source = 'tevo'
       AND q.sub_listing_id IS NOT NULL
       AND q.sub_ea IS NOT NULL
       AND q.n2s_id > 0
       AND COALESCE(i.status, '') NOT IN ('n2b', 'n2b_closed')
       AND lower(COALESCE(q.s4k_source, '')) LIKE ANY (ARRAY['evo%', 'gotickets%', 'seatgeek%', 'vivid%'])
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
    IF COALESCE(r.is_owned, false)                      THEN v_reasons := array_append(v_reasons, 'our_own_listing'); END IF;
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
    -- 20261029170000: level mismatch, one listing per order, time budget for the seller to accept our buy
    v_reasons := v_reasons || public.n2s_dryrun_extra_reasons(r.n2s_id, 'tevo', r.sub_listing_id,
                                                              r.section, r.sub_section, r.timer_expires_at);

    INSERT INTO public.n2s_gt_order_dryrun (
      sub_source, n2s_id, order_number, s4k_source, event_name, event_date, tevo_event_id,
      gt_event_id, sold_section, sold_row, sold_qty, sold_ea,
      sub_listing_id, sub_section, sub_row, sub_qty, quoted_ea, quoted_total,
      cover_cost, cover_gate, cover_label,
      live_price_ea, live_qty, live_splits, live_pulled_at, sub_view,
      seconds_left, decision, skip_reasons, per_order_cap, daily_cap, day_spend_before, payload)
    VALUES (
      'tevo', r.n2s_id, r.order_number, r.s4k_source, r.event_name, r.event_date, r.tevo_event_id,
      NULL, r.section, r.order_row, r.quantity, r.sold_ea,
      r.sub_listing_id, r.sub_section, r.sub_row, r.sub_qty, r.sub_ea, r.sub_total,
      r.cover_cost, r.cover_gate, r.cover_label,
      r.live_price, r.live_qty, r.live_splits, r.live_pulled_at, v_view,
      GREATEST(0, extract(epoch FROM (r.timer_expires_at - now())))::int,
      CASE WHEN cardinality(v_reasons) = 0 THEN 'would_buy' ELSE 'skip' END,
      v_reasons, p_per_order_cap, p_daily_cap, v_spend,
      jsonb_build_object(
        '_dry_run',  true,
        '_not_sent', 'Dry run only. Nothing calls TEvo (20261028220000).',
        'endpoint',  'POST https://api.ticketevolution.com/v9/orders',
        'orders',    jsonb_build_array(jsonb_build_object(
            'ticket_group', jsonb_build_object('id', r.sub_listing_id, 'price', r.sub_ea),
            'quantity',     r.sub_qty,
            'seller_id',    NULL,
            'external_notes', 'N2S cover for ' || COALESCE(r.s4k_source, '?') || ' order ' || r.order_number)),
        '_reference', jsonb_build_object(
            'quoted_ea', r.sub_ea, 'quoted_total', r.sub_total,
            'cover_cost', r.cover_cost, 'buy_url', r.buy_url)))
    ON CONFLICT ON CONSTRAINT n2s_gt_order_dryrun_once DO NOTHING;

    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

REVOKE EXECUTE ON FUNCTION public.n2s_dryrun_extra_reasons(bigint, text, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.n2s_gt_order_dryrun_capture(numeric, numeric, integer[]) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.n2s_evo_order_dryrun_capture(numeric, numeric, integer[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_dryrun_extra_reasons(bigint, text, text, text, text, timestamptz) TO service_role;
