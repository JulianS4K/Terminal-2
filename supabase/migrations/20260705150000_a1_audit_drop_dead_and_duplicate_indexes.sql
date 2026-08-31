-- ============================================================================
-- Migration 20260705150000 — drop dead/invalid/duplicate indexes (audit sweep)
--
-- Lane:     A1 (data plane)
-- Touches:  listings_snapshots (W), seatgeek_listings_snapshots (W),
--           event_metrics (W), seatgeek_event_metrics (W),
--           seatgeek_performer_xref (W), seatgeek_venue_xref (W),
--           performer_espn_team_xref (W), espn_attendance_snapshots (W),
--           venue_assets (W), seatdata_event_stats (W), listing_xref (W)
-- Pre-reqs: 20260619200000 (first dead-firehose-index drop wave)
--
-- Applied to prod 2026-07-05 via MCP (DROP INDEX CONCURRENTLY, operator-
-- directed supabase-audit session). This file is the canonical record; all
-- statements are IF EXISTS no-ops on replay. Plain DROP here (not
-- CONCURRENTLY) so branch replays inside a transaction succeed.
--
-- Three groups:
-- (a) invalid failed-CIC remnants (indisvalid=false, two still receiving
--     writes on the hottest table): listings_snapshots_prev_retail_null_idx
--     (1.9GB), listings_snapshots_price_change_idx (22MB),
--     idx_sg_listings_captured (0B). These were the "2 blocked" drops from
--     A1-OPS-16..21 pillar 2 (blocked by the A1-OPS-24 stuck txn, since
--     terminated) — re-created concurrently at some point and left invalid.
-- (b) dead partial index listings_snapshots_event_id_aq_null_idx (1.94GB):
--     predicate `WHERE aq_short_event_id IS NULL` matches 100% of rows (the
--     column was never populated; its backfill cron was tombstoned
--     2026-06-01, mig 20260601120000).
-- (c) exact-duplicate indexes (same indkey/indclass/expr/pred as a surviving
--     constraint-backed or unique sibling — planner redirects, verified via
--     EXPLAIN post-drop) + the never-scanned listing_xref_method_conf_idx
--     (90MB; match_method/confidence are single-valued in practice).
-- ============================================================================

-- (a) invalid failed-CIC remnants
drop index if exists public.listings_snapshots_prev_retail_null_idx;
drop index if exists public.listings_snapshots_price_change_idx;
drop index if exists public.idx_sg_listings_captured;

-- (b) dead partial index for the tombstoned aq backfill
drop index if exists public.listings_snapshots_event_id_aq_null_idx;

-- (c) exact duplicates of constraint-backed/unique siblings + unused
drop index if exists public.idx_event_metrics_time;            -- dup of event_metrics_pkey (event_id, captured_at)
drop index if exists public.idx_sg_em_event;                   -- dup of seatgeek_event_metrics_dedup
drop index if exists public.idx_sg_perfxref_name;              -- dup of sg_perf_xref_name_uniq
drop index if exists public.idx_sg_venuexref_name;             -- dup of sg_venue_xref_name_uniq
drop index if exists public.performer_espn_team_xref_team_idx; -- dup of petx_espn_reverse_uniq
drop index if exists public.idx_espn_att_team_captured;        -- dup of espn_attendance_snapshots_..._captured_key
drop index if exists public.idx_venue_assets_espn_venue_id;    -- dup of venue_assets_espn_venue_id_uniq
drop index if exists public.idx_sd_stats_event_ts;             -- dup of seatdata_stats_dedup
drop index if exists public.listing_xref_method_conf_idx;      -- 0 scans since creation; constant-valued cols

-- Rollback (if ever needed — recreate CONCURRENTLY on prod):
--   create index concurrently listings_snapshots_event_id_aq_null_idx
--     on public.listings_snapshots (event_id) where aq_short_event_id is null;
--   (duplicate-group siblings and original defs: see git history of the
--    creating migrations; the surviving sibling of each pair is unchanged.)
