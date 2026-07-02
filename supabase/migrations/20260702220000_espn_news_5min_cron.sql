-- ============================================================================
-- Migration 20260702220000 — ESPN news: refresh every 5 minutes
--
-- Lane:     D0 (author) → A1 (apply)   [D0 has no prod-DB apply authority]
-- Touches:  cron.job (W, via cron.schedule), cron_policy (W, one row)
-- Pre-reqs: espn-collect edge fn with ?scope=news (v7, this PR) deployed;
--           public._cron_invoke_edge_fn(text, jsonb), public.cron_should_fire(text),
--           public.cron_policy (all pre-existing).
--
-- WHY: espn_news only refreshed DAILY — collectNews() runs solely under the
--   espn-collect `team_daily` scope (espn-team-daily @ 05:00 UTC). The 10-min
--   `gameday` scope pulls scores/odds, NOT news. So the D0 NEWS WIRE's ESPN
--   headlines were up to ~24h stale (verified 2026-07-02: newest article ~15h
--   old across all leagues). Operator directive: refresh ESPN every 5 min.
--
-- HOW: the new `?scope=news` edge-fn route does a LIGHTWEIGHT league-level pull
--   (one /news call per distinct league slug, ~7 requests) — sustainable at a
--   5-min cadence without the ~200 per-team calls of `team_daily` (which would
--   rate-limit ESPN). This schedules it every 5 min, wrapped in the standard
--   cron_should_fire() gate.
--
--   cron_policy row: min-interval 4 min (NOT 5) on purpose — a '*/5' cron ticks
--   ~5 min apart, but clock jitter can make (now - last_fire) momentarily < 5m
--   and the gate would skip that tick (→ effectively every 10 min). A 4-min
--   floor guarantees every 5-min tick clears the gate while still blocking an
--   accidental double-fire. No daily cap, no work_check (news always worth a
--   pull). enabled → operator can pause via cron_policy without unscheduling.
--
-- Read-only vs upstream: ESPN is a public GET data source (RULE 2 is about
--   broker listing/order APIs — N/A). No prod-data mutation in this file beyond
--   the cron/policy registration; the apply itself is A1/operator-gated.
-- ============================================================================

-- Policy knob (upsert so re-apply is idempotent).
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('espn-news-5min', '{}'::int[], 4, 4, NULL, NULL, true,
   'D0 NEWS WIRE: league-level ESPN news every 5 min (espn-collect?scope=news). '
   '4-min floor guarantees the */5 cron clears the gate despite tick jitter.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql           = EXCLUDED.work_check_sql,
  daily_max_fires          = EXCLUDED.daily_max_fires,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

-- (Re)schedule the 5-min news cron. Unschedule first so re-apply doesn't error.
SELECT cron.unschedule('espn-news-5min')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-news-5min');

SELECT cron.schedule(
  'espn-news-5min',
  '*/5 * * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('espn-news-5min') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=news',
      '{}'::jsonb);
  END $body$;
  $cron$
);
