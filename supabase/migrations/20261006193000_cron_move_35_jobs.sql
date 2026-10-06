-- Migration 20261006193000 · level:data-collection · lane:A1 (operator-routed from D7) · writes:cron.job · reads:cron.job · pre:20261006170040
--
-- Already applied to prod · via MCP 2026-10-06 ~19:25 UTC under operator direction
-- ("yes move the :35 jobs, test first"), after a rolled-back dry run (both
-- alter_job calls took, schedules read back as 17 / 28, prod unchanged after).
--
-- ============================================================================
-- Move two hourly jobs off :35, the most congested minute on the scheduler.
--
-- FOUND (2026-10-06): the N2S CRM fetch (n2s_crm_direct_20s, every 30 s) fails
-- 39% of the time in the :35–:39 window vs 6–20% at every other minute, and
-- starts only about half as often there. Over 24 h the jobs that start at :35
-- account for ~925 busy-seconds per hour-slot, and several of them die with
-- "job startup timeout" after ~2 minutes waiting for a worker:
--   resolve-aq-tevo-from-sources-hourly  12/24 failed (startup timeout)
--   performer-stat-card-refresh           2/6
--   gt_map_events_hourly                  ~142 s per run
-- The two hourly ones move to minutes that start < 15 busy-seconds per hour
-- and avoid the :02/:05/:07 marks (PR checklist):
--   536 gt_map_events_hourly                 35 * * * *  ->  17 * * * *
--   320 resolve-aq-tevo-from-sources-hourly  35 * * * *  ->  28 * * * *
-- Commands are untouched; only the minute changes. Guarded on name + current
-- schedule, so a re-apply after anyone else moves them is a no-op.
-- ============================================================================

DO $mig$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobid = 536 AND jobname = 'gt_map_events_hourly' AND schedule = '35 * * * *') THEN
    PERFORM cron.alter_job(536, schedule := '17 * * * *');
  ELSE
    RAISE NOTICE 'cron 536 gt_map_events_hourly not at 35 * * * *; skipped';
  END IF;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobid = 320 AND jobname = 'resolve-aq-tevo-from-sources-hourly' AND schedule = '35 * * * *') THEN
    PERFORM cron.alter_job(320, schedule := '28 * * * *');
  ELSE
    RAISE NOTICE 'cron 320 resolve-aq-tevo-from-sources-hourly not at 35 * * * *; skipped';
  END IF;
END $mig$;

-- rollback:
--   SELECT cron.alter_job(536, schedule := '35 * * * *');
--   SELECT cron.alter_job(320, schedule := '35 * * * *');
