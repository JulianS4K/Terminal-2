-- ============================================================================
-- Migration 20260910003000 — scope the sub-queue refresh off the POLLERS' OWN
--                            state, not off the snapshot tables
--
-- Lane:     D0 (orders surface) reading A1's poll state
-- Touches:  s4kcs_sub_worklist_refresh() (CREATE OR REPLACE FUNCTION)
--           reads evo_listings_poll_state, gt_listings_poll_state,
--           gotickets_event, v_sub_orders
-- Pre-reqs: 20260910000000 (the function this replaces)
--
-- READ-ONLY UPSTREAM (RULE 2): pure DB, no outbound call.
--
-- WHY. The first version answered "which events moved?" by scanning
-- `listings_snapshots` and `gotickets_listings_snapshots` for recent
-- captured_at. Those are ~171M and ~166M rows. Doing that every 10 minutes to
-- recover a fact the pollers ALREADY RECORD is both expensive and indirect:
-- it infers the poll from its side effects instead of reading the poll.
--
-- `evo_listings_poll_state` (16,480 rows) and `gt_listings_poll_state`
-- (101,833 rows) each carry `last_polled_listings_at` per event. Together that
-- is ~118k rows against ~337M — the same question, four orders of magnitude
-- cheaper, and it is the pollers' own account of what they did rather than our
-- reconstruction of it.
--
-- ⚠ STILL A FOLLOWER, DELIBERATELY. This reads the pollers' state; it is NOT
-- called from inside cron 321 `evo_listings_poll_2min` or the GoTickets poll.
-- Appending a D0 refresh to an A1 ingest job would couple this queue's failure
-- modes and runtime to ingest's — a slow refresh would start delaying the
-- polling that feeds it. Reading state keeps the two independent while making
-- the handoff exact.
--
-- ⚠ THE TWO STATE TABLES ARE KEYED DIFFERENTLY. `evo_listings_poll_state.
-- event_id` IS the TEvo event id, but `gt_listings_poll_state` is keyed on
-- `gt_event_id` and must go through `gotickets_event` to reach one. A GoTickets
-- event we have not mapped yet therefore contributes nothing here — correct,
-- since an unmapped event has no orders to refresh either.
--
-- ⚠ THE WINDOW STILL OVERSHOOTS THE SCHEDULE (12 min against a 10-min cron).
-- Poll state is a timestamp, not a queue: an event polled in the gap between
-- two refreshes is simply not seen, and the miss is silent because a stale
-- queue row looks exactly like a fresh one. The overlap is the whole guard.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.s4kcs_sub_worklist_refresh(
  p_since      interval DEFAULT interval '12 minutes',
  p_statuses   text[]   DEFAULT NULL,
  p_event_ids  bigint[] DEFAULT NULL
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
  IF p_event_ids IS NOT NULL THEN
    v_events := p_event_ids;
  ELSIF p_since IS NULL THEN
    -- v_sub_orders, not s4kcs_orders: EVO orders are in no CRM feed, so
    -- scoping off the base table would never refresh an EVO event.
    SELECT array_agg(DISTINCT s.tevo_event_id) INTO v_events
      FROM public.v_sub_orders s
     WHERE s.event_date >= current_date AND s.tevo_event_id IS NOT NULL;
  ELSE
    -- What the POLLERS say they polled, not what the snapshot tables imply.
    SELECT array_agg(DISTINCT e) INTO v_events FROM (
      SELECT es.event_id AS e
        FROM public.evo_listings_poll_state es
       WHERE es.last_polled_listings_at >= now() - p_since
      UNION
      SELECT ge.tevo_event_id
        FROM public.gt_listings_poll_state gs
        JOIN public.gotickets_event ge ON ge.gt_event_id = gs.gt_event_id
       WHERE gs.last_polled_listings_at >= now() - p_since
         AND ge.tevo_event_id IS NOT NULL
    ) polled
     WHERE e IN (SELECT DISTINCT tevo_event_id FROM public.v_sub_orders
                  WHERE event_date >= current_date AND tevo_event_id IS NOT NULL);
  END IF;

  IF v_events IS NULL OR cardinality(v_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0; RETURN;
  END IF;

  DELETE FROM public.s4kcs_sub_worklist w
   WHERE w.tevo_event_id = ANY(v_events);

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
  'Rebuild the substitution queue for events the EVO and GoTickets pollers '
  'report polling in the last p_since. Scopes off evo_listings_poll_state and '
  'gt_listings_poll_state (~118k rows) rather than the listings snapshot tables '
  '(~337M) -- the same question, far cheaper, and it reads the pollers own '
  'account instead of inferring it from captured_at. Still a FOLLOWER: it is '
  'not called from inside an A1 poll job, so a slow refresh can never delay the '
  'ingest that feeds it. gt_listings_poll_state is keyed on gt_event_id and '
  'goes through gotickets_event to reach a tevo id. p_since NULL rebuilds every '
  'future event; p_event_ids overrides the scope. REPLACES rows in scope: '
  'current state, not history. Orders with no candidate are still written with '
  'candidates=0. Calls s4kcs_sub_candidates() rather than reimplementing the '
  'match rules. Window must OVERSHOOT the cron schedule -- poll state is a '
  'timestamp, not a queue, so an event polled in the gap is silently missed.';

REVOKE ALL ON FUNCTION public.s4kcs_sub_worklist_refresh(interval,text[],bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.s4kcs_sub_worklist_refresh(interval,text[],bigint[]) TO service_role;
