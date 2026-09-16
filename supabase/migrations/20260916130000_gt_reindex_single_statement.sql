-- ============================================================================
-- Migration 20260916130000 — the REINDEX jobs must be ONE statement, so the
--                            900s role ceiling is a hard bound, not a setting
-- Migration 20260916130000 · level:data-collection · lane:A1 · writes:cron.job · reads:pg_index,pg_class · pre:20260914220000
--
-- Lane:     A1 (data plane)
-- Touches:  cron.job (W) — maintenance jobs only; no table, data or schema change
-- Pre-reqs: 20260914220000 (the migration this fixes)
--
-- ── THE BUG ────────────────────────────────────────────────────────────────
-- gt_reindex_event_time_weekly, first run after 20260914220000, 2026-09-16
-- 07:30:00 UTC, failed in 0.035 seconds:
--
--     ERROR:  REINDEX CONCURRENTLY cannot run inside a transaction block
--
-- 20260914220000 fixed the 900s timeout by prefixing the command with
-- `SET statement_timeout='4h'; SET lock_timeout='60s';`. pg_cron sends a job's
-- command string as a single simple-query message, and a multi-statement simple
-- query is executed inside ONE implicit transaction. Adding the SETs therefore
-- put the REINDEX in a transaction block, which REINDEX CONCURRENTLY refuses.
--
-- The previous form (bare REINDEX, one statement) did run — it just inherited
-- `statement_timeout=900s` from the `postgres` role's rolconfig. The two
-- failure modes are mutually exclusive: you cannot SET the timeout without
-- creating the transaction block that forbids the command.
--
-- ── WHY THERE IS NO WAY AROUND THE 900s ───────────────────────────────────
-- Every escape was checked against this instance, not assumed:
--   * `cron.schedule_in_database(..., username := ...)` — scheduling a job for
--     another role requires superuser; `postgres` here has rolsuper = false.
--   * A dedicated maintenance role with its own statement_timeout — same
--     superuser requirement, so it cannot be reached from cron.
--   * Raising the timeout on the `postgres` role, globally or per-database,
--     would lift the 15-minute guard off every session in the database to
--     serve three weekly jobs. Not worth it.
--   * dblink (run the REINDEX top-level on a second connection that CAN set
--     its own timeout) and pg_repack are both available but neither is
--     installed; dblink additionally needs connection credentials in the job
--     body. Installing either is an operator decision, not a bug fix.
--
-- So: back to one bare statement per job, and the work has to fit in 900s.
--
-- ── WHAT FITS, AND WHAT DOES NOT ──────────────────────────────────────────
--   idx_gt_ls_captured     3599 MB   scheduled — expected to fit
--   idx_gt_ls_event_time   6999 MB   scheduled — expected to fit, unproven
--   ..._snapshots_pkey       33 GB   RETIRED — demonstrably does not fit
--
-- The pkey is the one that matters most (~28 GB of the reclaimable bloat, and
-- the hottest index on the table) and it is the one cron cannot do: its single
-- attempt burned the full 900s without finishing. Leaving the job scheduled
-- would mean a weekly 900s of offpeak IO that reclaims nothing and leaves an
-- invalid index behind each time, so it is unscheduled here.
--
-- It is not lost work — it folds into the maintenance-window decision already
-- pending with the operator (VACUUM FULL / pg_repack on
-- gotickets_listings_snapshots, ~65 GB of heap). VACUUM FULL rebuilds the heap
-- AND every index on the table, so that one window reclaims the pkey, both
-- remaining indexes and the heap together. A standalone pkey rebuild needs the
-- same thing this does: a session whose statement_timeout is not the role's.
--
-- ── THE _ccnew CLEANUP JOBS ───────────────────────────────────────────────
-- A REINDEX CONCURRENTLY killed by the timeout leaves `<index>_ccnew` behind,
-- invalid and unusable, and it must be dropped before the next attempt. That
-- cleanup cannot live in the reindex job (two statements = transaction block =
-- the bug above) and cannot live in a DO block (DROP INDEX CONCURRENTLY is
-- likewise forbidden in one), so each index gets its own single-statement drop
-- five minutes ahead of its rebuild.
--
-- The name is deterministic, and DROP INDEX CONCURRENTLY IF EXISTS is a no-op
-- in the normal case where the last run succeeded. `_ccnew` is only ever a
-- live, valid index while a REINDEX CONCURRENTLY is actually running; at :25,
-- with the rebuild not starting until :30 and bounded to 900s (ending by :45),
-- nothing of this schedule can be in flight.
--
-- Verified before applying: `SELECT count(*) FROM pg_index WHERE NOT indisvalid`
-- = 0. The 09-16 failure was instant, so it left nothing behind.
-- ============================================================================

-- ── idx_gt_ls_event_time (6999 MB) — Wednesdays ───────────────────────────
SELECT cron.unschedule('gt_reindex_event_time_ccnew_cleanup')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_event_time_ccnew_cleanup');
SELECT cron.schedule(
  'gt_reindex_event_time_ccnew_cleanup',
  '25 7 * * 3',
  $cron$ DROP INDEX CONCURRENTLY IF EXISTS public.idx_gt_ls_event_time_ccnew; $cron$);

SELECT cron.unschedule('gt_reindex_event_time_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_event_time_weekly');
SELECT cron.schedule(
  'gt_reindex_event_time_weekly',
  '30 7 * * 3',
  $cron$ REINDEX INDEX CONCURRENTLY public.idx_gt_ls_event_time; $cron$);

-- ── idx_gt_ls_captured (3599 MB) — Fridays ────────────────────────────────
SELECT cron.unschedule('gt_reindex_captured_ccnew_cleanup')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_captured_ccnew_cleanup');
SELECT cron.schedule(
  'gt_reindex_captured_ccnew_cleanup',
  '25 7 * * 5',
  $cron$ DROP INDEX CONCURRENTLY IF EXISTS public.idx_gt_ls_captured_ccnew; $cron$);

SELECT cron.unschedule('gt_reindex_captured_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_captured_weekly');
SELECT cron.schedule(
  'gt_reindex_captured_weekly',
  '30 7 * * 5',
  $cron$ REINDEX INDEX CONCURRENTLY public.idx_gt_ls_captured; $cron$);

-- ── gotickets_listings_snapshots_pkey (33 GB) — retired from cron ─────────
-- Cannot complete inside the 900s the role imposes; see the header. Handled in
-- the operator maintenance window together with the heap, not weekly from cron.
SELECT cron.unschedule('gt_reindex_pkey_weekly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_reindex_pkey_weekly');

-- One-off: clear the pkey's leftover if a future manual attempt leaves one.
-- (None exists now — pg_index NOT indisvalid = 0 at apply time — so no
-- standing job is scheduled for it.)
