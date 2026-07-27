-- ============================================================================
-- Migration 20260704010100 — ESPN attendance: poll daily
--
-- Touches:  cron.job (W), cron_policy (W, one row)
-- Pre-reqs: espn-league-collect edge fn (?scope=attendance) deployed;
--           espn_attendance_snapshots table (mig 20260704010000);
--           public._cron_invoke_edge_fn, public.cron_should_fire, public.cron_policy.
--
-- WHY: season attendance moves slowly (a handful of home games per team per
--   week), so a daily change-only snapshot is plenty. 06:10 UTC — just after the
--   espn-team-daily standings pull, staggered from the transactions cron.
--
-- Read-only vs upstream: ESPN is a public GET data source (RULE 2 N/A).
-- ============================================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('espn-attendance-daily', '{}'::int[], 1380, 1380, NULL, 2, true,
   'ESPN season attendance once daily (espn-league-collect?scope=attendance). '
   '23h floor keeps the daily cron single-firing; change-only snapshots.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql           = EXCLUDED.work_check_sql,
  daily_max_fires          = EXCLUDED.daily_max_fires,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

SELECT cron.unschedule('espn-attendance-daily')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-attendance-daily');

SELECT cron.schedule(
  'espn-attendance-daily',
  '10 6 * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('espn-attendance-daily') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-league-collect?scope=attendance',
      '{}'::jsonb);
  END $body$;
  $cron$
);
