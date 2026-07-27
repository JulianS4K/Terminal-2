-- ============================================================================
-- Migration 20260704110100 — ESPN MMA (UFC) fight cards: poll daily
--
-- Touches:  cron.job (W), cron_policy (W, one row)
-- Pre-reqs: espn-mma edge fn deployed; espn_mma_events table (mig 20260704110000);
--           _cron_invoke_edge_fn, cron_should_fire, cron_policy.
--
-- WHY: the UFC scoreboard surfaces the current/featured card; a daily pull stores
--   it (+ rotates to the next as events approach and firms up results afterward).
--   06:40 UTC, staggered after the other daily ESPN pulls.
--
-- Read-only vs upstream: ESPN is a public GET data source (RULE 2 N/A).
-- ============================================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('espn-mma-daily', '{}'::int[], 1380, 1380, NULL, 2, true,
   'ESPN UFC fight cards once daily (espn-mma): scoreboard -> fightcenter.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql           = EXCLUDED.work_check_sql,
  daily_max_fires          = EXCLUDED.daily_max_fires,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

SELECT cron.unschedule('espn-mma-daily')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-mma-daily');

SELECT cron.schedule(
  'espn-mma-daily',
  '40 6 * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('espn-mma-daily') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-mma',
      '{}'::jsonb);
  END $body$;
  $cron$
);
