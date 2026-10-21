-- Migration 20261021180000 · level:secondary-sales · lane:D7 · writes:n2s_gt_order_dryrun,n2s_gt_order_dryrun_capture,n2s_cover_queue(trigger) · reads:n2s_cover_queue,n2s_gt_current,n2s_items,gotickets_event · pre:20261006193000
--
--
-- Already applied to prod · via MCP 2026-10-21 ~20:00 UTC (version 20261021200027)
-- under operator direction, after rolled-back tests on prod (synthetic orders:
-- in-section live cover → would_buy; $2,500 → over_order_cap; gate 3 →
-- gate_moves_buyer; expired timer → timer_closed; re-run adds nothing; a price
-- move on a bought order → already_bought) and a trigger-path test.
-- ============================================================================
-- GoTickets auto-buy DRY RUN: log the order we WOULD place, never place it.
--
-- Operator direction 2026-10-21: "do a dry run on it with no actual purchase
-- going forward so we can check".
--
-- ⚠ NOTHING HERE CALLS GOTICKETS OR ANY OTHER UPSTREAM API. RULE 2 untouched:
-- gotickets_client.py stays GET-only and no http_post is added anywhere. Each
-- row is the exact Pro API `POST /orders` body an auto-buyer would send, plus
-- the decision it would take — stored, never sent.
--
-- HOW IT RUNS: a statement trigger on n2s_cover_queue. The queue is rebuilt
-- on every fast_land / pipeline tick (DELETE + INSERT), so each rebuild calls
-- n2s_gt_order_dryrun_capture(), which records every GoTickets cover it has
-- not seen before — at the moment it first appears, which is when a real
-- auto-buyer would act. No new cron job. The trigger swallows its own errors
-- (WARNING only), so the dry run can never break the cover pipeline.
--
-- ONE ROW per (order, listing, quoted price). A cover whose price moves is a
-- new decision and gets a new row; the same cover seen on the next tick is not.
--
-- DECISION — 'would_buy' only when every check passes, else 'skip' with every
-- failing reason listed (skip_reasons), so the log answers "why not" too:
--   gate_moves_buyer    cover_gate not in p_gates (default 1,2: same section;
--                       3-6 are "offer subs" and move the buyer)
--   obstructed_view     listing notes say obstructed / limited view
--   no_gt_event_id      the TEvo event is not mapped to a GoTickets event
--   listing_gone        not in n2s_gt_current any more
--   price_up            live all-in price above the quoted price
--   qty_unavailable     live quantity below what we need
--   split_not_allowed   the listing will not sell exactly sub_qty
--   order_closed        the N2S order is terminal
--   timer_closed        outside the order's response window
--   event_started       event start time has passed
--   over_order_cap      quoted total above p_per_order_cap
--   over_daily_cap      today's (ET) would_buy total + this above p_daily_cap
--   already_bought      this order already has a would_buy row
--
-- The caps (p_per_order_cap $2,000, p_daily_cap $15,000 per ET day) and the
-- allowed gates are dry-run defaults to be reviewed — change them in
-- n2s_gt_order_dryrun_trg(), not by editing rows.
--
-- payload.expectedTotal stays NULL: it needs tax and the card's
-- transactionRatePercentage, neither of which we store
-- (docs/buy_side_evo_gotickets.md). The human-only fields (payment token,
-- delivery method, contact, recipient) stay NULL for the same reason as in
-- n2s_buy_intent.
--
-- rollback:
--   DROP TRIGGER IF EXISTS n2s_gt_order_dryrun_after_refresh ON public.n2s_cover_queue;
--   DROP FUNCTION IF EXISTS public.n2s_gt_order_dryrun_trg();
--   DROP FUNCTION IF EXISTS public.n2s_gt_order_dryrun_capture(numeric, numeric, int[]);
--   DROP TABLE IF EXISTS public.n2s_gt_order_dryrun;
-- ============================================================================

-- CREATE TRIGGER briefly locks n2s_cover_queue against the 15 s refresh;
-- fail fast instead of queueing the pipeline behind this migration.
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS public.n2s_gt_order_dryrun (
  dryrun_id        bigserial PRIMARY KEY,
  captured_at      timestamptz NOT NULL DEFAULT now(),
  n2s_id           bigint      NOT NULL,
  order_number     text,
  s4k_source       text,
  event_name       text,
  event_date       date,
  tevo_event_id    bigint,
  gt_event_id      bigint,
  sold_section     text,
  sold_row         text,
  sold_qty         integer,
  sold_ea          numeric,
  sub_listing_id   text        NOT NULL,
  sub_section      text,
  sub_row          text,
  sub_qty          integer,
  quoted_ea        numeric     NOT NULL,
  quoted_total     numeric,
  cover_cost       numeric,
  cover_gate       integer,
  cover_label      text,
  live_price_ea    numeric,
  live_qty         integer,
  live_splits      integer[],
  live_pulled_at   timestamptz,
  sub_view         text,
  decision         text        NOT NULL CHECK (decision IN ('would_buy', 'skip')),
  skip_reasons     text[]      NOT NULL DEFAULT '{}',
  per_order_cap    numeric,
  daily_cap        numeric,
  day_spend_before numeric,
  payload          jsonb       NOT NULL,
  CONSTRAINT n2s_gt_order_dryrun_once UNIQUE (n2s_id, sub_listing_id, quoted_ea)
);

CREATE INDEX IF NOT EXISTS n2s_gt_order_dryrun_captured_idx
  ON public.n2s_gt_order_dryrun (captured_at DESC);

ALTER TABLE public.n2s_gt_order_dryrun ENABLE ROW LEVEL SECURITY;
-- Guarded drops instead of DROP ... IF EXISTS: the "does not exist, skipping"
-- NOTICE those emit on a fresh apply hangs the Supabase MCP SQL tools.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
              AND tablename = 'n2s_gt_order_dryrun' AND policyname = 'n2s_gt_order_dryrun_sel') THEN
    DROP POLICY n2s_gt_order_dryrun_sel ON public.n2s_gt_order_dryrun;
  END IF;
END $$;
CREATE POLICY n2s_gt_order_dryrun_sel ON public.n2s_gt_order_dryrun
  FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.n2s_gt_order_dryrun FROM anon;

COMMENT ON TABLE public.n2s_gt_order_dryrun IS
  'GoTickets auto-buy DRY RUN (20261021180000): the Pro API POST /orders body '
  'an auto-buyer would send for each GoTickets cover, and whether it would '
  'buy (decision) or why not (skip_reasons). NOTHING IS SENT — no upstream '
  'call exists anywhere in this pipeline.';

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.n2s_gt_order_dryrun_capture(
  p_per_order_cap numeric DEFAULT 2000,
  p_daily_cap     numeric DEFAULT 15000,
  p_gates         int[]   DEFAULT '{1,2}'
)
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
       AND NOT EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
                        WHERE d.n2s_id = q.n2s_id
                          AND d.sub_listing_id = q.sub_listing_id
                          AND d.quoted_ea = q.sub_ea)
     ORDER BY q.fifo_position NULLS LAST, q.n2s_id
  LOOP
    v_reasons := '{}';
    v_view := CASE WHEN r.live_notes IS NULL THEN 'unknown'
                   ELSE public.n2s_view_of(r.live_notes, NULL) END;

    -- recomputed per row so a would_buy earlier in this loop counts
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

REVOKE ALL ON FUNCTION public.n2s_gt_order_dryrun_capture(numeric, numeric, int[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_gt_order_dryrun_capture(numeric, numeric, int[]) TO service_role;
COMMENT ON FUNCTION public.n2s_gt_order_dryrun_capture(numeric, numeric, int[]) IS
  'GoTickets auto-buy DRY RUN: records each new GoTickets cover in '
  'n2s_gt_order_dryrun with the order body and the would_buy/skip decision. '
  'Sends nothing (20261021180000).';

-- ---------------------------------------------------------------------------
-- Statement trigger: runs once per queue rebuild. Errors are downgraded to a
-- WARNING so the dry run can never fail n2s_cover_queue_refresh().
CREATE OR REPLACE FUNCTION public.n2s_gt_order_dryrun_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  BEGIN
    PERFORM public.n2s_gt_order_dryrun_capture(2000, 15000, '{1,2}');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'n2s_gt_order_dryrun_capture failed: % (%)', SQLERRM, SQLSTATE;
  END;
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_gt_order_dryrun_trg() FROM PUBLIC, anon;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'n2s_gt_order_dryrun_after_refresh'
              AND tgrelid = 'public.n2s_cover_queue'::regclass) THEN
    DROP TRIGGER n2s_gt_order_dryrun_after_refresh ON public.n2s_cover_queue;
  END IF;
END $$;
CREATE TRIGGER n2s_gt_order_dryrun_after_refresh
  AFTER INSERT ON public.n2s_cover_queue
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.n2s_gt_order_dryrun_trg();
