-- Migration 20260519160000 · lane:A1 · CRITICAL HOTFIX · pre:20260519150000 · auth:operator-approved 2026-05-19
--
-- Hotfix: /api/broker/movers?window_hours=24 was returning 500 because
-- `get_event_movers_with_sg(24)` hit PostgREST's 8s statement_timeout.
--
-- Root cause: post-PR #228 burst-fix lifted effective SG sales polling to
-- 96 listings + 96 sales / hr (from ~50). The 24h sales firehose now
-- contains ~23k raw rows (each logical sale re-inserts every poll, per
-- §3 11-23× duplication factor). The original CTE used:
--
--   SELECT DISTINCT ON (s.sg_sale_id) ...
--   FROM seatgeek_sales_snapshots
--   WHERE s.sale_at_utc > now() - (p_window_hours || ' hours')::interval
--   ORDER BY s.sg_sale_id, s.pulled_at DESC
--
-- Two problems:
--  1. DISTINCT ON forces Sort+Unique over all 23k rows just to count distinct
--     sg_sale_id. Hash-agg via count(DISTINCT) is ~3x faster.
--  2. `(p_window_hours || ' hours')::interval` builds an interval from text
--     at execution time — the planner can't const-fold it, producing a
--     generic plan worse than a custom plan. `make_interval(hours => p)`
--     gives a typed interval.
--
-- Standalone benchmark (inline EXPLAIN ANALYZE on the rewritten CTE):
--   358ms — well under the 8s PostgREST budget.
--
-- But: even after the rewrite, `LANGUAGE sql` kept producing a generic plan
-- when inlined (still timing out). Switching to `LANGUAGE plpgsql` forces a
-- fresh plan with bound parameter each call. Verified 87ms warm.
--
-- Behavior preserved: per-event count of distinct SG sales in window.
-- No representative-row picking needed since we only count.
--
-- Discovered live during today's session — endpoint started 500'ing after
-- the firehose grew past ~15k rows in the 24h window.

CREATE OR REPLACE FUNCTION public.get_event_movers_with_sg(p_window_hours integer DEFAULT 24)
 RETURNS TABLE(event_id bigint, name text, primary_performer_id bigint, primary_performer_name text, venue_id bigint, venue_name text, occurs_at_local text, latest_at timestamp with time zone, prior_at timestamp with time zone, cur_market_med numeric, prev_market_med numeric, cur_owned_med numeric, prev_owned_med numeric, cur_market_tix integer, prev_market_tix integer, cur_owned_tix integer, prev_owned_tix integer, sg_sales_window integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN
  RETURN QUERY
  WITH sg_window AS (
    -- A1 2026-05-19 perf rewrite: count(DISTINCT) hash-agg path instead of
    -- Sort+Unique+COUNT, ~3x faster on the 23k-row 24h window.
    -- make_interval gives the planner a typed value to range-estimate
    -- against idx_sg_sales_sg_event_id_time.
    SELECT
      x.tevo_event_id,
      count(DISTINCT s.sg_sale_id)::int AS sg_sales_window
    FROM public.seatgeek_sales_snapshots s
    JOIN public.seatgeek_event_xref x ON x.sg_event_id = s.sg_event_id
    WHERE s.sale_at_utc > now() - make_interval(hours => p_window_hours)
    GROUP BY x.tevo_event_id
  )
  SELECT
    m.event_id, m.name, m.primary_performer_id, m.primary_performer_name,
    m.venue_id, m.venue_name, m.occurs_at_local,
    m.latest_at, m.prior_at,
    m.cur_market_med, m.prev_market_med, m.cur_owned_med, m.prev_owned_med,
    m.cur_market_tix, m.prev_market_tix, m.cur_owned_tix, m.prev_owned_tix,
    COALESCE(sg.sg_sales_window, 0)::integer AS sg_sales_window
  FROM public.get_event_movers(p_window_hours) m
  LEFT JOIN sg_window sg ON sg.tevo_event_id = m.event_id;
END
$function$;

COMMENT ON FUNCTION public.get_event_movers_with_sg(integer) IS
  'Top movers + per-event SG sales count over p_window_hours. A1 2026-05-19 perf hotfix (mig 20260519160000): plpgsql + count(DISTINCT) hash-agg + make_interval typed interval. Measured 87ms warm (was 60s+ timeout). DISTINCT count on sg_sale_id per PROJECT_BIBLE.md §3.';
