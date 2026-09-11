-- ============================================================================
-- Migration 20260910000000 — s4kcs_sub_worklist: the substitution QUEUE
--
-- Lane:     D0 (CRM orders surface) reading A1's listing snapshot tables
-- Touches:  s4kcs_sub_worklist (CREATE TABLE),
--           s4kcs_sub_worklist_refresh() (CREATE FUNCTION),
--           reads s4kcs_orders + s4kcs_sub_candidates() (mig 20260909223000)
-- Pre-reqs: 20260909223000 (the matcher this calls),
--           20260909221000 (v_sub_orders — our books first, CRM as fallback)
--
-- READ-ONLY UPSTREAM (RULE 2): no outbound call at all. Pure DB.
--
-- The screen was pull-only: a broker pasted ONE order number, resolved it, and
-- ran the checker for that ONE ticket. This is the sweep that turns it into a
-- queue -- every order, refreshed on the cadence the listing books already
-- refresh at, so the work arrives instead of being asked for.
--
-- ── This is CURRENT STATE, not an answer log ────────────────────────────────
-- Operator direction 2026-09-09: "we don't need to store answers, just push it
-- through, but maintain a results table that updates on gotix and evo
-- scheduled pulls." So the table holds ONE row per order carrying only the
-- BEST candidate and a count -- never the full candidate list, never history.
-- A refresh REPLACES the rows in its scope. The authoritative per-order detail
-- is still computed live by `/api/broker/event/{id}/substitutions`
-- (core/substitutions.py), which is richer than the SQL matcher: GA rows,
-- splits, landed cost, an `ambiguous` bucket, and the zoned-vs-zoned rule.
-- The queue answers "which orders need looking at"; the route answers "what
-- exactly do I buy". Do not grow this table into a second answer surface.
--
-- ── It calls the matcher, it does not reimplement it ────────────────────────
-- The row/section/quantity/total rules and their landmines live in
-- `s4kcs_sub_candidates()` (mig 20260909223000). This function calls it with
-- p_per_order=1. A third copy of that logic is exactly how the section and row
-- rules would drift apart.
--
-- ⚠ TEST SCOPE: EVERY ORDER IS TREATED AS NEEDING A SUB. Operator direction --
-- "assume for now all orders are to be subbed to test". So p_statuses defaults
-- to NULL (every status, not just the v_s4kcs_sub_status signals) and orders
-- with NO candidate are still inserted, with candidates = 0, so the queue shows
-- the whole book rather than only the lucky rows. Narrowing to the at-risk
-- statuses later is a one-argument change, NOT a rewrite.
--
-- All six marketplaces now enter the queue. GoTickets and Vivid used to be
-- excluded for having no usable price; both are repaired from our own books in
-- v_s4kcs_orders (mig 20260909220000), which this reads instead of the base
-- table -- that is ~6.8k of ~28k future orders that were previously invisible.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.s4kcs_sub_worklist (
  source              text        NOT NULL,
  s4k_order_id        text        NOT NULL,
  tevo_event_id       bigint,
  event_name          text,
  event_date          date,
  venue_name          text,
  order_status        text,
  sub_signal          text,
  section             text,
  order_row           text,
  quantity            integer,
  sold_ea             numeric,
  sold_total          numeric,
  -- best candidate only (see "current state, not an answer log" above)
  candidates          integer     NOT NULL DEFAULT 0,
  best_sub_source     text,
  best_price_basis    text,
  best_listing_id     bigint,
  best_section        text,
  best_row            text,
  best_qty            integer,
  best_ea             numeric,
  best_total          numeric,
  margin_ea           numeric,
  margin_total        numeric,
  rows_closer         integer,
  buy_url             text,
  listing_captured_at timestamptz,
  refreshed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, s4k_order_id)
);

COMMENT ON TABLE public.s4kcs_sub_worklist IS
  'Substitution QUEUE: one row per CRM order with its BEST substitute, if any. '
  'Current state, replaced on refresh — not an answer log and not history. '
  'candidates=0 means the order is in scope but nothing qualified. The full '
  'per-order answer is computed live by /api/broker/event/{id}/substitutions.';

CREATE INDEX IF NOT EXISTS idx_sub_worklist_margin
  ON public.s4kcs_sub_worklist (margin_total DESC NULLS LAST)
  WHERE candidates > 0;
CREATE INDEX IF NOT EXISTS idx_sub_worklist_event
  ON public.s4kcs_sub_worklist (tevo_event_id);
CREATE INDEX IF NOT EXISTS idx_sub_worklist_date
  ON public.s4kcs_sub_worklist (event_date);

ALTER TABLE public.s4kcs_sub_worklist ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.s4kcs_sub_worklist FROM PUBLIC, anon;
GRANT SELECT ON public.s4kcs_sub_worklist TO authenticated, service_role;

-- ── The refresh ─────────────────────────────────────────────────────────────
-- Scope defaults to "events whose listing book actually moved in the last
-- p_since", which is what makes this ride the GoTickets and EVO pull cadence
-- WITHOUT editing either poller. Touching cron 321 `evo_listings_poll_2min` or
-- the GoTickets pull to bolt a call on the end would put a D0 concern inside an
-- A1 job and couple the queue's failure modes to ingest's; a follower job that
-- reads what they wrote stays independent.
CREATE OR REPLACE FUNCTION public.s4kcs_sub_worklist_refresh(
  p_since      interval DEFAULT interval '10 minutes',  -- NULL = every future event
  p_statuses   text[]   DEFAULT NULL,                   -- NULL = every status (test scope)
  p_event_ids  bigint[] DEFAULT NULL                    -- explicit override
)
RETURNS TABLE(events_refreshed integer, orders_written integer, with_candidate integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_events bigint[];
  v_orders int := 0;
  v_hits   int := 0;
BEGIN
  -- 1. what to refresh
  IF p_event_ids IS NOT NULL THEN
    v_events := p_event_ids;
  ELSIF p_since IS NULL THEN
    -- v_sub_orders, not s4kcs_orders: EVO orders exist in NO CRM feed, so
    -- scoping off the base table would silently never refresh an EVO event.
    SELECT array_agg(DISTINCT s.tevo_event_id) INTO v_events
      FROM public.v_sub_orders s
     WHERE s.event_date >= current_date AND s.tevo_event_id IS NOT NULL;
  ELSE
    -- events whose GoTickets or TEvo book moved since the last pull
    SELECT array_agg(DISTINCT e) INTO v_events FROM (
      SELECT g.tevo_event_id AS e
        FROM public.gotickets_listings_snapshots g
       WHERE g.captured_at >= now() - p_since
      UNION
      SELECT t.event_id
        FROM public.listings_snapshots t
       WHERE t.captured_at >= now() - p_since
    ) moved
     WHERE e IN (SELECT DISTINCT tevo_event_id FROM public.v_sub_orders
                  WHERE event_date >= current_date AND tevo_event_id IS NOT NULL);
  END IF;

  IF v_events IS NULL OR cardinality(v_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0; RETURN;
  END IF;

  -- 2. replace this scope (current state, never appended)
  DELETE FROM public.s4kcs_sub_worklist w
   WHERE w.tevo_event_id = ANY(v_events);

  -- 3. every in-scope order, with its best candidate if one exists
  WITH scope AS (
    SELECT s.source, s.order_id AS s4k_order_id, s.tevo_event_id, s.event_name, s.event_date,
           s.venue_name, s.order_status, s.section, s."row" AS order_row, s.quantity,
           s.price_per_ticket AS sold_ea
      FROM public.v_sub_orders s
     WHERE s.tevo_event_id = ANY(v_events)
       AND s.event_date >= current_date
       AND (p_statuses IS NULL OR s.order_status = ANY(p_statuses))
       AND s.price_per_ticket IS NOT NULL
  ),
  best AS (
    SELECT DISTINCT ON (c.source, c.s4k_order_id) c.*
      FROM public.s4kcs_sub_candidates(
             p_statuses  => p_statuses,
             p_per_order => 1,
             p_event_ids => v_events) c
     ORDER BY c.source, c.s4k_order_id, c.sub_ea
  ),
  cnt AS (
    SELECT c.source, c.s4k_order_id, count(*)::int AS n
      FROM public.s4kcs_sub_candidates(
             p_statuses  => p_statuses,
             p_per_order => 2147483647,
             p_event_ids => v_events) c
     GROUP BY 1, 2
  ),
  ins AS (
    INSERT INTO public.s4kcs_sub_worklist (
      source, s4k_order_id, tevo_event_id, event_name, event_date, venue_name,
      order_status, sub_signal, section, order_row, quantity, sold_ea, sold_total,
      candidates, best_sub_source, best_price_basis, best_listing_id, best_section,
      best_row, best_qty, best_ea, best_total, margin_ea, margin_total,
      rows_closer, buy_url, listing_captured_at, refreshed_at)
    SELECT sc.source, sc.s4k_order_id, sc.tevo_event_id, sc.event_name, sc.event_date,
           sc.venue_name, sc.order_status, b.sub_signal, sc.section, sc.order_row,
           sc.quantity, round(sc.sold_ea, 2), round(sc.sold_ea * sc.quantity, 2),
           COALESCE(n.n, 0), b.sub_source, b.sub_price_basis, b.sub_listing_id,
           b.sub_section, b.sub_row, b.sub_qty, b.sub_ea, b.sub_total,
           b.margin_ea, b.margin_total, b.rows_closer, b.buy_url, b.captured_at, now()
      FROM scope sc
      LEFT JOIN best b ON b.source = sc.source AND b.s4k_order_id = sc.s4k_order_id
      LEFT JOIN cnt  n ON n.source = sc.source AND n.s4k_order_id = sc.s4k_order_id
    RETURNING (best_listing_id IS NOT NULL) AS had_sub
  )
  SELECT count(*)::int, count(*) FILTER (WHERE had_sub)::int INTO v_orders, v_hits FROM ins;

  RETURN QUERY SELECT cardinality(v_events), v_orders, v_hits;
END $function$;

COMMENT ON FUNCTION public.s4kcs_sub_worklist_refresh(interval,text[],bigint[]) IS
  'Rebuild the substitution queue for events whose GoTickets or TEvo book moved '
  'in the last p_since (so it rides the existing pull cadence without editing '
  'either poller — a follower job, not a bolt-on inside an A1 cron). '
  'p_since NULL rebuilds every future event; p_event_ids overrides the scope. '
  'REPLACES rows in scope: current state, not history. Orders with no candidate '
  'are still written with candidates=0 so the queue shows the whole book. Calls '
  's4kcs_sub_candidates() rather than reimplementing the match rules.';

REVOKE ALL ON FUNCTION public.s4kcs_sub_worklist_refresh(interval,text[],bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.s4kcs_sub_worklist_refresh(interval,text[],bigint[]) TO service_role;

-- ── Cron (authored, NOT scheduled here) ─────────────────────────────────────
-- Scheduling is a Rule 1 write and an operator action. When approved:
--
--   SELECT cron.schedule('s4kcs_sub_worklist_refresh_10min', '*/10 * * * *',
--     $$ DO $b$ BEGIN
--          IF NOT public.cron_should_fire('s4kcs_sub_worklist_refresh_10min')
--            THEN RETURN; END IF;
--          PERFORM public.s4kcs_sub_worklist_refresh(interval '12 minutes');
--        END $b$; $$);
--
-- The 12-minute window deliberately OVERSHOOTS the 10-minute cadence: a window
-- that merely matches the schedule drops any event whose capture lands in the
-- gap between two runs, and the miss is silent because the queue simply shows
-- a stale row. Same overshoot reasoning as the venue sweep's `current_date-10`
-- against the mapper's 7-day lookback (PROJECT_BIBLE §4).
