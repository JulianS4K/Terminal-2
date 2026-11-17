-- ============================================================================
-- Migration 20260910510000 — carry gate/label/zone into n2s_cover_queue
--
-- Lane: D7 · Pre-reqs: 20260910420000
--
-- The gate cascade added cover_gate, cover_label, order_zone and sub_zone to
-- n2s_cover_candidates, but the QUEUE table, the n2s_covers() allocator and
-- n2s_cover_queue_refresh() were never widened to carry them — so the label
-- died one step downstream and nothing (panel, feed, history) could see it.
-- Surfaced by n2s_cover_history_append() failing on "column c.cover_gate does
-- not exist": the appender was right and the plumbing was missing.
--
-- Additive: four nullable columns, a widened allocator, a widened INSERT.
-- ============================================================================

ALTER TABLE public.n2s_cover_queue
  ADD COLUMN IF NOT EXISTS cover_gate  integer,
  ADD COLUMN IF NOT EXISTS cover_label text,
  ADD COLUMN IF NOT EXISTS order_zone  text,
  ADD COLUMN IF NOT EXISTS sub_zone    text;

COMMENT ON COLUMN public.n2s_cover_queue.cover_gate IS
  'Gate 1-6 from the label cascade. Filter on THIS, not cover_label text: the gate integers are stable, the wording may be clarified.';
COMMENT ON COLUMN public.n2s_cover_queue.cover_label IS
  'Human/workflow label. "offer subs" means the buyer is being MOVED and must accept before purchase; " repost single" means sub_qty is one over the obligation.';

DROP FUNCTION IF EXISTS public.n2s_covers(bigint[], interval, integer, text[]);

CREATE FUNCTION public.n2s_covers(
  p_n2s_ids         bigint[] DEFAULT NULL::bigint[],
  p_max_listing_age interval DEFAULT '01:00:00'::interval,
  p_per_order       integer  DEFAULT 3,
  p_sub_sources     text[]   DEFAULT NULL::text[])
RETURNS TABLE(n2s_id bigint, order_number text, s4k_source text, n2s_status text,
              fail_reason text, timer_expired boolean, event_name text,
              event_date date, venue text, tevo_event_id bigint, section text,
              order_row text, quantity integer, sold_ea numeric, sub_source text,
              sub_listing_id text, sub_section text, sub_row text, sub_qty integer,
              sub_avail integer, sub_ea numeric, sub_total numeric,
              cover_cost numeric, rows_closer integer, buy_url text,
              captured_at timestamptz, cover_rank bigint, fifo_position bigint,
              cover_gate integer, cover_label text, order_zone text, sub_zone text)
LANGUAGE sql
STABLE
SET search_path TO 'public','pg_temp'
AS $function$
  WITH c AS (
    SELECT * FROM public.n2s_cover_candidates(p_n2s_ids, p_max_listing_age,
                                              p_per_order, p_sub_sources)
  ),
  -- one listing may cover only one obligation: greedy allocation, best gate
  -- first, then cheapest, then oldest obligation (FIFO).
  a AS (
    SELECT c.*,
           row_number() OVER (PARTITION BY c.sub_source, c.sub_listing_id
                              ORDER BY c.cover_gate, c.cover_cost, c.n2s_id) AS listing_claim,
           row_number() OVER (PARTITION BY c.n2s_id
                              ORDER BY c.cover_gate, c.cover_cost) AS fifo_position
      FROM c
  )
  SELECT n2s_id, order_number, s4k_source, n2s_status, fail_reason, timer_expired,
         event_name, event_date, venue, tevo_event_id, section, order_row,
         quantity, sold_ea, sub_source, sub_listing_id, sub_section, sub_row,
         sub_qty, sub_avail, sub_ea, sub_total, cover_cost, rows_closer,
         buy_url, captured_at, cover_rank, fifo_position,
         cover_gate, cover_label, order_zone, sub_zone
    FROM a
   WHERE listing_claim = 1 AND fifo_position = 1
   ORDER BY cover_gate, cover_cost, n2s_id;
$function$;

REVOKE ALL ON FUNCTION public.n2s_covers(bigint[], interval, integer, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_covers(bigint[], interval, integer, text[]) TO service_role, authenticated;

CREATE OR REPLACE FUNCTION public.n2s_cover_queue_refresh()
RETURNS TABLE(rows_written integer, orders_covered integer, total_cover_cost numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  DELETE FROM public.n2s_cover_queue;

  INSERT INTO public.n2s_cover_queue (
    n2s_id, order_number, s4k_source, n2s_status, fail_reason, timer_expired,
    event_name, event_date, venue, tevo_event_id, section, order_row, quantity,
    sold_ea, sub_source, sub_listing_id, sub_section, sub_row, sub_qty,
    sub_avail, sub_ea, sub_total, cover_cost, rows_closer, buy_url,
    captured_at, cover_rank, fifo_position, refreshed_at,
    cover_gate, cover_label, order_zone, sub_zone)
  SELECT c.n2s_id, c.order_number, c.s4k_source, c.n2s_status, c.fail_reason,
         c.timer_expired, c.event_name, c.event_date, c.venue, c.tevo_event_id,
         c.section, c.order_row, c.quantity, c.sold_ea, c.sub_source,
         c.sub_listing_id, c.sub_section, c.sub_row, c.sub_qty, c.sub_avail,
         c.sub_ea, c.sub_total, c.cover_cost, c.rows_closer, c.buy_url,
         c.captured_at, c.cover_rank, c.fifo_position, now(),
         c.cover_gate, c.cover_label, c.order_zone, c.sub_zone
    FROM public.n2s_covers() c;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN QUERY
    SELECT v_n,
           (SELECT count(*)::int FROM public.n2s_cover_queue),
           (SELECT round(COALESCE(sum(cover_cost), 0), 2) FROM public.n2s_cover_queue);
END $function$;
