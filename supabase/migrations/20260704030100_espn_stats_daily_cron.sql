-- ============================================================================
-- Migration 20260704030100 — ESPN player stats: poll daily
--
-- Touches:  cron.job (W), cron_policy (W, one row)
-- Pre-reqs: espn-league-collect edge fn (?scope=stats) deployed;
--           espn_player_stats table (mig 20260704030000);
--           public._cron_invoke_edge_fn, public.cron_should_fire, public.cron_policy.
--
-- WHY: full-roster stats (~1.8k athletes across MLB batting+pitching / NBA /
--   WNBA) change once a day at most for a completed slate; a daily bulk-upsert
--   snapshot keeps the current-season table fresh. 06:20 UTC, staggered after the
--   attendance (06:10) and standings (05:00) pulls.
--
-- Read-only vs upstream: ESPN is a public GET data source (RULE 2 N/A).
-- ============================================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('espn-stats-daily', '{}'::int[], 1380, 1380, NULL, 2, true,
   'ESPN full-roster player stats once daily (espn-league-collect?scope=stats). '
   '23h floor keeps the daily cron single-firing; current-season bulk upsert.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql           = EXCLUDED.work_check_sql,
  daily_max_fires          = EXCLUDED.daily_max_fires,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

SELECT cron.unschedule('espn-stats-daily')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-stats-daily');

SELECT cron.schedule(
  'espn-stats-daily',
  '20 6 * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('espn-stats-daily') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-league-collect?scope=stats',
      '{}'::jsonb);
  END $body$;
  $cron$
);
