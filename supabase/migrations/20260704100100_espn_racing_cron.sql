-- ============================================================================
-- Migration 20260704100100 — ESPN racing standings: poll daily
--
-- Touches:  cron.job (W), cron_policy (W, one row)
-- Pre-reqs: espn-racing edge fn deployed; espn_racing_standings table
--           (mig 20260704100000); _cron_invoke_edge_fn, cron_should_fire, cron_policy.
--
-- WHY: driver championship standings move at most once per race weekend, so a
--   daily bulk-upsert snapshot (F1 + NASCAR Cup/Xfinity/Truck, ~200 drivers) is
--   plenty. 06:30 UTC, staggered after the other daily ESPN pulls.
--
-- Read-only vs upstream: ESPN is a public GET data source (RULE 2 N/A).
-- ============================================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('espn-racing-daily', '{}'::int[], 1380, 1380, NULL, 2, true,
   'ESPN racing standings once daily (espn-racing): F1 + NASCAR Cup/Xfinity/Truck.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql           = EXCLUDED.work_check_sql,
  daily_max_fires          = EXCLUDED.daily_max_fires,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

SELECT cron.unschedule('espn-racing-daily')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-racing-daily');

SELECT cron.schedule(
  'espn-racing-daily',
  '30 6 * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('espn-racing-daily') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-racing',
      '{}'::jsonb);
  END $body$;
  $cron$
);
