-- ============================================================================
-- Migration 20260914220050 — give the REINDEX jobs a statement_timeout that fits the work
-- Migration 20260914220050 · level:data-collection · lane:A1 · writes:cron.job · reads:pg_roles · pre:20260911236500
--
-- Lane:     A1 (data plane)
-- Touches:  cron.job (W) — three maintenance jobs re-scheduled; no data change
-- Pre-reqs: 20260911236500 (the migration this fixes)
--
-- ── THE BUG ────────────────────────────────────────────────────────────────
-- gt_reindex_pkey_weekly failed on its very first run, 2026-09-13 07:30 UTC:
--
--     ERROR:  canceling statement due to statement timeout
--     (after exactly 900.0 seconds)
--
-- Cause: the `postgres` role — which pg_cron runs jobs as — carries
-- `statement_timeout=900s` in its rolconfig:
--
--     postgres | {search_path="$user", public, extensions, statement_timeout=900s}
--
-- 20260911236500 scheduled all three REINDEX jobs with no `SET
-- statement_timeout`, so they silently inherited that 15-minute ceiling. A
-- REINDEX CONCURRENTLY of a 33 GB btree on an IO-constrained instance needs
-- far longer. Every other job touched in that PR was given an explicit
-- timeout; these three were the omission, and the 15-minute default was
-- invisible because it lives on the role rather than in the job.
--
-- ── THE COLLATERAL ─────────────────────────────────────────────────────────
-- A cancelled REINDEX CONCURRENTLY leaves an INVALID index behind, and
-- PostgreSQL will not let the next attempt proceed cleanly around it. This one
-- left `gotickets_listings_snapshots_pkey_ccnew` — invalid, not ready, 0 bytes
-- (killed before it wrote any data, so no space was wasted). It was removed
-- with `DROP INDEX CONCURRENTLY` before this migration was applied; verified
-- afterwards with `SELECT count(*) FROM pg_index WHERE NOT indisvalid` = 0.
-- Any future failure of these jobs needs the same cleanup before a retry.
--
-- ── THE FIX ────────────────────────────────────────────────────────────────
-- statement_timeout = 4h, sized against the offpeak window rather than against
-- a guess at the rebuild time: starting 07:30 UTC, a 4h ceiling ends by 11:30
-- UTC = 07:30 ET, and offpeak runs to ET 08:59. REINDEX CONCURRENTLY holds no
-- blocking lock, so a long runtime costs only its own IO — the timeout exists
-- to stop it bleeding into peak, not to bound the work.
--
-- lock_timeout = 60s is added as well: REINDEX CONCURRENTLY takes brief
-- ShareUpdateExclusive locks at start and finish, and against a live firehose
-- it should give up rather than queue behind a long writer.
--
-- Applied to prod 2026-09-14 ~22:15 UTC under the same operator direction as
-- the original set; this file is the idempotent codification.
-- ============================================================================

SELECT cron.unschedule('gt_reindex_pkey_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_pkey_weekly');
SELECT cron.schedule(
  'gt_reindex_pkey_weekly',
  '30 7 * * 0',
  $cron$ SET statement_timeout='4h'; SET lock_timeout='60s';
         REINDEX INDEX CONCURRENTLY public.gotickets_listings_snapshots_pkey; $cron$);

SELECT cron.unschedule('gt_reindex_event_time_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_event_time_weekly');
SELECT cron.schedule(
  'gt_reindex_event_time_weekly',
  '30 7 * * 3',
  $cron$ SET statement_timeout='4h'; SET lock_timeout='60s';
         REINDEX INDEX CONCURRENTLY public.idx_gt_ls_event_time; $cron$);

SELECT cron.unschedule('gt_reindex_captured_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_captured_weekly');
SELECT cron.schedule(
  'gt_reindex_captured_weekly',
  '30 7 * * 5',
  $cron$ SET statement_timeout='4h'; SET lock_timeout='60s';
         REINDEX INDEX CONCURRENTLY public.idx_gt_ls_captured; $cron$);
