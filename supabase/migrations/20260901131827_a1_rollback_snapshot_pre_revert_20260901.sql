-- Purpose:  Pre-rollback snapshot so the 2026-09-01 revert is itself reversible.
-- Touches:  rollback_snapshot_20260901_cron (NEW, W), rollback_snapshot_20260901_counts (NEW, W)
-- Lane:     A1  ·  Applied to prod 2026-09-01 under operator direction.
--
-- Captures cron.job and the key row counts as they stood at the END of branch
-- claude/pause-tickets-data-crons-gt85nq, immediately before the rollback to
-- e43d549. Nothing reads these tables; they exist only so the rollback can be
-- undone. Recorded here because the file must exist for the prod ledger entry
-- (supabase_migrations version 20260901131827) to have a home in git.

CREATE TABLE IF NOT EXISTS public.rollback_snapshot_20260901_cron (
  jobid       bigint,
  jobname     text,
  schedule    text,
  command     text,
  active      boolean,
  captured_at timestamptz
);
INSERT INTO public.rollback_snapshot_20260901_cron (jobid, jobname, schedule, command, active, captured_at)
  SELECT jobid, jobname, schedule, command, active, now() FROM cron.job
  WHERE NOT EXISTS (SELECT 1 FROM public.rollback_snapshot_20260901_cron);

CREATE TABLE IF NOT EXISTS public.rollback_snapshot_20260901_counts (
  metric text,
  value  bigint
);
INSERT INTO public.rollback_snapshot_20260901_counts (metric, value)
  SELECT * FROM (
    SELECT 'events'::text,                 count(*)::bigint FROM public.events
    UNION ALL SELECT 'aq_event_map',           count(*) FROM public.aq_event_map
    UNION ALL SELECT 'cross_source_venue_map', count(*) FROM public.cross_source_venue_map
    UNION ALL SELECT 'cron_active',            count(*) FROM cron.job WHERE active
  ) s
  WHERE NOT EXISTS (SELECT 1 FROM public.rollback_snapshot_20260901_counts);
