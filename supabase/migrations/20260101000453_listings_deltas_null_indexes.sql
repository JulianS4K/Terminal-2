-- ============================================================================
-- A1 cron-cascade fix (2026-05-17) — listings_deltas_backfill index gap.
--
-- A1's PR #189 (mig 20260517000000) correctly rewrote
-- listings_deltas_backfill_chunked: 5-min timeout, smallest-first, COALESCE
-- sentinel, EXISTS check. But it's still 15/15 failing today because the
-- function's FIRST statement is:
--
--   SELECT event_id, count(*) FROM listings_snapshots
--   WHERE prev_retail_price IS NULL AND event_id IS NOT NULL
--   GROUP BY event_id ORDER BY rcnt ASC LIMIT p_max_events
--
-- This is an 8.4M-row sequential scan filtered on `IS NULL`. The only existing
-- partial index (listings_snapshots_price_change_idx) is on the OPPOSITE
-- predicate (prev_retail_price IS NOT NULL), so the planner falls back to
-- seq-scan + sort + group, which can't finish in 5 min.
--
-- Same problem on seatgeek_listings_snapshots (3.7M rows, same query shape).
--
-- Fix: two partial indexes on (event_id) WHERE prev_*_price IS NULL.
-- Negligible disk cost (576 distinct events × 4 bytes pre-tuple), turns the
-- 5-min scan into an index-only scan returning in <100ms.
-- ============================================================================

CREATE INDEX CONCURRENTLY IF NOT EXISTS listings_snapshots_prev_retail_null_idx
  ON public.listings_snapshots (event_id)
  WHERE prev_retail_price IS NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS sg_listings_snapshots_prev_bc_null_idx
  ON public.seatgeek_listings_snapshots (sg_event_id)
  WHERE prev_broadcast_price IS NULL;

COMMENT ON INDEX public.listings_snapshots_prev_retail_null_idx IS
  'Partial index supporting listings_deltas_backfill_chunked initial event scan. Drops when prev_retail_price becomes non-null.';
COMMENT ON INDEX public.sg_listings_snapshots_prev_bc_null_idx IS
  'Partial index supporting listings_deltas_backfill_chunked seatgeek leg.';
