-- ============================================================================
-- Migration 20260910120000 — materialise the allocated N2S covers so the
--                            terminal can read them cheaply
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_cover_queue (CREATE TABLE), n2s_cover_queue_refresh(), one cron
-- Pre-reqs: 20260910110000
--
-- READ-ONLY upstream: no API call. Pure SELECT over already-ingested data.
--
-- Operator direction 2026-09-09: "map and push the sub listing data out."
--
-- ── ⚠ WHY A TABLE AND NOT AN ENDPOINT OVER n2s_covers() ───────────────────
-- n2s_covers() is VOLATILE: it runs the four-source matcher, builds temp
-- tables and does a sequential FIFO allocation. That is correct for computing
-- an answer and completely wrong to hang an HTTP endpoint off — every page
-- load, every refresh, every idle browser tab would re-run the matcher. The
-- same mistake was already made and fixed once in this pipeline (the covers
-- "view" that re-ran the matcher on every SELECT, migration 20260910050000).
--
-- So the cron computes ONCE and writes here, and the API reads precomputed
-- rows — exactly the shape s4kcs_sub_worklist already uses for the main queue.
--
-- ⚠ THE TABLE IS A CACHE, NOT A LEDGER. It is fully replaced on every refresh,
-- because a cover is only true for as long as the listing is live: under the
-- 1-hour freshness rule a row older than an hour is not stale data to be
-- reconciled, it is WRONG. `refreshed_at` is therefore load-bearing — a
-- consumer must show it, and treat an old one as "no answer" rather than "no
-- covers". Never add an upsert-and-keep path here.
--
-- ⚠ ALLOCATION IS GLOBAL, SO THE REFRESH CANNOT BE SCOPED. FIFO exclusivity
-- means order N's cover depends on what orders 1..N-1 took. Refreshing a
-- subset would hand the same listing to two orders again — the exact defect
-- 20260910100000 fixed. DELETE-all + INSERT-all in one transaction is the only
-- correct shape; do not "optimise" this into a per-event refresh.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.n2s_cover_queue (
  n2s_id           bigint PRIMARY KEY,
  order_number     text NOT NULL,
  s4k_source       text,
  n2s_status       text,
  fail_reason      text,
  timer_expired    boolean,
  event_name       text,
  event_date       date,
  venue            text,
  tevo_event_id    bigint,
  section          text,
  order_row        text,
  quantity         integer,
  sold_ea          numeric,
  sub_source       text,
  sub_listing_id   text,
  sub_section      text,
  sub_row          text,
  sub_qty          integer,
  sub_ea           numeric,
  sub_total        numeric,
  cover_cost       numeric,
  rows_closer      integer,
  buy_url          text,
  captured_at      timestamptz,
  cover_rank       bigint,
  fifo_position    bigint,
  refreshed_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS n2s_cover_queue_cost_idx  ON public.n2s_cover_queue (cover_cost);
CREATE INDEX IF NOT EXISTS n2s_cover_queue_event_idx ON public.n2s_cover_queue (event_date);
ALTER TABLE public.n2s_cover_queue ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.n2s_cover_queue IS
  'Precomputed ALLOCATED N2S covers: one listing per order, one order per '
  'listing, FIFO by alert_at. A CACHE, fully replaced each refresh — a cover '
  'is only true while the listing is live, so under the 1-hour freshness rule '
  'a stale row is WRONG, not merely old. Consumers must surface refreshed_at '
  'and read an old one as "no answer", never as "no covers".';

CREATE OR REPLACE FUNCTION public.n2s_cover_queue_refresh()
RETURNS TABLE(rows_written integer, orders_covered integer, total_cover_cost numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  -- Whole-table replace inside one transaction: allocation is global (see
  -- header), so a partial refresh would re-create double-offered listings.
  DELETE FROM public.n2s_cover_queue;

  INSERT INTO public.n2s_cover_queue (
    n2s_id, order_number, s4k_source, n2s_status, fail_reason, timer_expired,
    event_name, event_date, venue, tevo_event_id, section, order_row, quantity,
    sold_ea, sub_source, sub_listing_id, sub_section, sub_row, sub_qty, sub_ea,
    sub_total, cover_cost, rows_closer, buy_url, captured_at, cover_rank,
    fifo_position, refreshed_at)
  SELECT c.n2s_id, c.order_number, c.s4k_source, c.n2s_status, c.fail_reason,
         c.timer_expired, c.event_name, c.event_date, c.venue, c.tevo_event_id,
         c.section, c.order_row, c.quantity, c.sold_ea, c.sub_source,
         c.sub_listing_id, c.sub_section, c.sub_row, c.sub_qty, c.sub_ea,
         c.sub_total, c.cover_cost, c.rows_closer, c.buy_url, c.captured_at,
         c.cover_rank, c.fifo_position, now()
    FROM public.n2s_covers() c;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN QUERY
    SELECT v_n,
           (SELECT count(*)::int FROM public.n2s_cover_queue),
           (SELECT round(COALESCE(sum(cover_cost), 0), 2) FROM public.n2s_cover_queue);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_cover_queue_refresh() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_queue_refresh() TO service_role;
REVOKE ALL ON public.n2s_cover_queue FROM PUBLIC, anon;
GRANT SELECT ON public.n2s_cover_queue TO authenticated, service_role;

-- Odd minutes, alongside the ping, so the screen and the ping agree.
SELECT cron.schedule(
  'n2s_cover_queue_refresh_2min', '1-59/2 * * * *',
  $cron$ SELECT public.n2s_cover_queue_refresh(); $cron$
);
