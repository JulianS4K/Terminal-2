-- ============================================================================
-- Migration 20260911236500 — reclaim the GoTickets index bloat online
-- Migration 20260911236500 · level:data-collection · lane:A1 · writes:cron.job · reads:pg_class,pg_index · pre:20260911250000,20260911235000
--
-- Lane:     A1 (data plane)
-- Touches:  cron.job (W) — maintenance jobs only; no table or data is altered
-- Pre-reqs: 20260911250000 (autovacuum tuning for the high-churn tables —
--           reindexing before that fix would simply re-bloat),
--           20260911235000 (the nightly VACUUM this schedules around)
--
-- 20260911250000 stopped gotickets_listings_snapshots GROWING. It could not
-- give back what is already allocated — it says so explicitly. Splitting that
-- 130 GB by where the waste actually sits:
--
--   object                              size     live estimate   bloat
--   gotickets_listings_snapshots_pkey   33 GB      ~5 GB         ~6x
--   idx_gt_ls_event_time              7.0 GB      ~4 GB         ~1.8x
--   idx_gt_ls_captured                3.6 GB      ~3 GB         ~1.2x
--   heap                               87 GB     ~21 GB         ~4x
--
-- The primary key alone is ~28 GB of reclaimable btree, and it is the hottest
-- index on the table (720,103,039 scans). Every one of those scans walks a
-- tree six times larger than it needs to be, on an instance with 2 GB of
-- shared_buffers — so this is a cache-residency problem, not merely a disk one.
--
-- REINDEX INDEX CONCURRENTLY is the right tool for the index half:
--   * it builds the replacement alongside the original and swaps at the end,
--     taking only brief ShareUpdateExclusive locks — readers and the firehose
--     writer are NOT blocked;
--   * it needs temp space for the NEW index (~5 GB), not a copy of the old;
--   * it is safe to repeat, so this doubles as ongoing bloat control.
-- It cannot run inside a transaction block, which is why it is scheduled as
-- cron commands rather than executed in this migration.
--
-- One index per night, on different days, all inside the offpeak window
-- (ET 02:00-08:59 => 07:30 UTC), so a rebuild never overlaps another or the
-- 07:10 UTC nightly VACUUM from 20260911235000.
--
-- ⚠ THE HEAP IS DELIBERATELY NOT TOUCHED HERE. Reclaiming the ~65 GB of heap
-- needs VACUUM FULL, which takes an ACCESS EXCLUSIVE lock for the whole
-- rewrite — every reader and the GT drain would block for the duration on a
-- 87 GB table — and needs free disk for a second copy. That is a maintenance
-- window decision for the operator, not something to bury in a migration or
-- run unattended from cron. pg_repack would avoid the lock but its extension
-- is not installed and it requires a client binary this environment does not
-- have. Doing nothing is also defensible: with autovacuum fixed the heap space
-- is reusable, so the table stops growing and refills itself.
-- ============================================================================

SELECT cron.unschedule('gt_reindex_pkey_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_pkey_weekly');
SELECT cron.schedule(
  'gt_reindex_pkey_weekly',
  '30 7 * * 0',
  $cron$ REINDEX INDEX CONCURRENTLY public.gotickets_listings_snapshots_pkey; $cron$);

SELECT cron.unschedule('gt_reindex_event_time_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_event_time_weekly');
SELECT cron.schedule(
  'gt_reindex_event_time_weekly',
  '30 7 * * 3',
  $cron$ REINDEX INDEX CONCURRENTLY public.idx_gt_ls_event_time; $cron$);

SELECT cron.unschedule('gt_reindex_captured_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_captured_weekly');
SELECT cron.schedule(
  'gt_reindex_captured_weekly',
  '30 7 * * 5',
  $cron$ REINDEX INDEX CONCURRENTLY public.idx_gt_ls_captured; $cron$);
