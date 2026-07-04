-- ============================================================================
-- Migration 20260704060100 — ESPN player game logs: rotating worker every 10 min
--
-- Touches:  cron.job (W), cron_policy (W, one row)
-- Pre-reqs: espn-league-collect edge fn (?scope=gamelog) deployed;
--           espn_player_gamelog table + espn_gamelog_next_batch (mig 20260704060000);
--           public._cron_invoke_edge_fn, public.cron_should_fire, public.cron_policy.
--
-- WHY: full-roster game logs (~3.2k active athletes across MLB/NBA/NFL/WNBA) can't
--   be fetched in one edge-fn pass (wall-clock limit). The worker processes the N
--   least-recently-synced athletes per invocation (espn_gamelog_next_batch), so a
--   frequent cron ROTATES through the whole roster and then keeps it fresh. At
--   limit=120 every 10 min that's ~27 passes (~4.5h) per full rotation.
--
-- HOW: cron_policy floor at 8 min so the */10 cron always clears cron_should_fire()
--   despite tick jitter. No daily cap. Each pass writes a marker row per athlete so
--   staleness always advances (athletes with no games don't re-fetch forever).
--
-- Read-only vs upstream: ESPN is a public GET data source (RULE 2 N/A).
-- ============================================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('espn-gamelog-10min', '{}'::int[], 8, 8, NULL, NULL, true,
   'ESPN player game logs, batched staleness rotation (espn-league-collect?scope=gamelog&limit=120). '
   '8-min floor guarantees the */10 cron clears the gate; ~4.5h per full-roster rotation.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql           = EXCLUDED.work_check_sql,
  daily_max_fires          = EXCLUDED.daily_max_fires,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

SELECT cron.unschedule('espn-gamelog-10min')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-gamelog-10min');

SELECT cron.schedule(
  'espn-gamelog-10min',
  '*/10 * * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('espn-gamelog-10min') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-league-collect?scope=gamelog&limit=120',
      '{}'::jsonb);
  END $body$;
  $cron$
);
