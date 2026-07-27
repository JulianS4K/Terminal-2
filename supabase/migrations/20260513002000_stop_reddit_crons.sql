-- Migration 20260513002000 · level:admin · lane:Audit/Push · writes:cron(unschedule reddit_queue_30min,reddit_process_30min,reddit_pending_sweep_daily) · reads:- · pre:20260513001000
-- P0 resource-pressure response 2026-05-12: Supabase performance advisor
-- flagged the project as "exhausting multiple resources." Reddit pipeline
-- (PR 20260509410000) has no active use case yet — operator directive 22:50 EDT:
-- "stop reddit pulls, no use case yet."
--
-- This migration unschedules the 3 reddit crons:
--   * reddit_queue_30min          (jobid 75, schedule */30)
--   * reddit_process_30min        (jobid 76, schedule 5-59/30)
--   * reddit_pending_sweep_daily  (jobid 77, schedule 40 3 * * *)
--
-- Function definitions (reddit_queue, reddit_process, reddit_pending_sweep)
-- are PRESERVED — only the schedules drop. Reactivation requires re-running
-- the cron.schedule() calls from 20260509410000 (or a successor migration).
--
-- Why: 18s mean per reddit_queue call × ~48 calls/day = ~14 minutes of DB
-- time/day spent on data nobody reads. Net wins:
--   * Drops jobid 75 from the expensive-query top-15 (1.5% of total)
--   * Frees pg_cron worker slots (was occasionally blocking other refreshes)
--   * Removes Reddit API call traffic (no quota, but unnecessary)
--
-- Tables retained, no data wiped — historical reddit_signals rows are still
-- queryable, just no new pulls. If reactivation is needed, see
-- 20260509410000_betting_odds_and_reddit_signals.sql lines 475-492 for the
-- original schedule blocks.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_queue_30min') THEN
    PERFORM cron.unschedule('reddit_queue_30min');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_process_30min') THEN
    PERFORM cron.unschedule('reddit_process_30min');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_pending_sweep_daily') THEN
    PERFORM cron.unschedule('reddit_pending_sweep_daily');
  END IF;
END $$;
