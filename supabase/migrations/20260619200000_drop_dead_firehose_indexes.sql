-- Migration 20260619200000 · lane:A1 (operator-directed) ·
--   writes (DDL): DROP INDEX CONCURRENTLY x6 on the snapshot firehoses
--   reads: none
--   ## PARTIALLY APPLIED 2026-06-19 (operator-approved). 4 of 6 dropped:
--     seatgeek_sales_snapshots_tevo_event_id_idx, sg_listings_price_change_idx,
--     idx_sg_listings_owned, sg_listings_snapshots_prev_bc_null_idx (~227 MB).
--   ## 2 on listings_snapshots — both now INVALID (indisvalid=false → already out
--     of every query plan, so the read-speed win is banked), physical removal
--     completing via in-flight CONCURRENTLY finalizers. The 3-day blocker was
--     terminated (A1-OPS-24), but the `midnight-catchup-sweep` cron keeps firing
--     (now self-capped at 5min via SET LOCAL) and its AccessShareLock cycles
--     delay the final removal phase. They finalize within a sweep cap; the
--     operator cron fix (A1-OPS-24) ends the interference. If they linger as
--     invalid, a plain `DROP INDEX` in a between-sweep gap finishes them.
--
-- GOAL: data-analysis SPEED (operator reframe 2026-06-19). Removing dead /
-- low-value indexes speeds the INGEST path (fewer indexes to maintain per
-- INSERT -> less write amplification -> less bloat) and frees shared_buffers
-- for the hot indexes. Full analysis: docs/archive/2026-06-19-snapshot-bloat-play.md.
--
-- The 6 below are dead (0 scans) or near-dead, or partial indexes that backed a
-- now-DISABLED backfill cron. Cumulative pg_stat_user_indexes.idx_scan at audit
-- time (2026-06-19), with size:
--   seatgeek_sales_snapshots_tevo_event_id_idx   109 MB  scans=0    (dead duplicate of idx_sg_sales_event_at)
--   sg_listings_price_change_idx                 9 MB    scans=0
--   listings_snapshots_price_change_idx          22 MB   scans=7
--   listings_snapshots_prev_retail_null_idx      1.2 GB  scans=116  (partial for the disabled aq-backfill)
--   sg_listings_snapshots_prev_bc_null_idx       101 MB  scans=179  (partial for the disabled backfill)
--   idx_sg_listings_owned                        8 MB    scans=9
-- NOT dropped here (verify access pattern first, follow-up): idx_sg_listings_sglid
-- (703 MB, 65), sg_listings_tevo_sglid_captured_idx (502 MB, 158).
--
-- ⚠ APPLY OUTSIDE A TRANSACTION — DROP INDEX CONCURRENTLY cannot run inside a
-- txn block. Run each statement individually (psql / non-wrapped apply). Online:
-- no ACCESS EXCLUSIVE table lock. Before applying, RE-VERIFY idx_scan is still
-- low over a meaningful window (pollers were paused 2026-06-19, so SG counts are
-- frozen) — pre-check query at the bottom.

DROP INDEX CONCURRENTLY IF EXISTS public.seatgeek_sales_snapshots_tevo_event_id_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.sg_listings_price_change_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.listings_snapshots_price_change_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.listings_snapshots_prev_retail_null_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.sg_listings_snapshots_prev_bc_null_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_sg_listings_owned;

-- ─────────────────────────────────────────────────────────────────────────────
-- PRE-CHECK (run before applying — confirm still low-scan):
--   SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
--   FROM pg_stat_user_indexes
--   WHERE indexrelname IN ('seatgeek_sales_snapshots_tevo_event_id_idx','sg_listings_price_change_idx',
--     'listings_snapshots_price_change_idx','listings_snapshots_prev_retail_null_idx',
--     'sg_listings_snapshots_prev_bc_null_idx','idx_sg_listings_owned');
--
-- ROLLBACK (recreate, also CONCURRENTLY / outside a txn):
--   CREATE INDEX CONCURRENTLY seatgeek_sales_snapshots_tevo_event_id_idx ON public.seatgeek_sales_snapshots
--     USING btree (tevo_event_id, sale_at_utc DESC NULLS LAST) WHERE (tevo_event_id IS NOT NULL AND sg_sale_id IS NOT NULL);
--   CREATE INDEX CONCURRENTLY sg_listings_price_change_idx ON public.seatgeek_listings_snapshots
--     USING btree (sg_event_id, captured_at) WHERE (prev_broadcast_price IS NOT NULL AND broadcast_price <> prev_broadcast_price);
--   CREATE INDEX CONCURRENTLY listings_snapshots_price_change_idx ON public.listings_snapshots
--     USING btree (event_id, captured_at) WHERE (prev_retail_price IS NOT NULL AND retail_price <> prev_retail_price);
--   CREATE INDEX CONCURRENTLY listings_snapshots_prev_retail_null_idx ON public.listings_snapshots
--     USING btree (event_id) WHERE (prev_retail_price IS NULL);
--   CREATE INDEX CONCURRENTLY sg_listings_snapshots_prev_bc_null_idx ON public.seatgeek_listings_snapshots
--     USING btree (sg_event_id) WHERE (prev_broadcast_price IS NULL);
--   CREATE INDEX CONCURRENTLY idx_sg_listings_owned ON public.seatgeek_listings_snapshots
--     USING btree (tevo_event_id, is_broker_owned) WHERE (is_broker_owned = true);
