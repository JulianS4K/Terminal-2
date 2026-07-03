-- Migration 20260703014500 · level:standard · lane:broadway (D3) · writes: · reads: · pre:20260703014000
--
-- Weekly cast-title sweeper. The daily poll (20260703014000) only watches shows
-- that already have a cast_wiki_title; most of the slate starts with none. This
-- weekly cron runs broadway-cast-collect in "discover" mode: it searches
-- Wikipedia for each title-less show, auto-sets a high-confidence article match
-- (so the daily poll picks it up next run), and logs low-confidence hits as
-- curator suggestions in broadway_cast_pull_log. Over a few weeks the daily
-- poll's coverage grows from the seeded handful to the whole tracked slate.
--
-- No schema changes — reuses the columns + log table from 20260703014000 and
-- the existing edge function (mode="discover"). Cron only.
--
-- RULE 1: cron.schedule is an Applier action — authored here, arms on apply (A1).
-- Sundays 14:11 UTC (avoids saturated :02/:05/:07 marks; 1 fire/week).

DO $body$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'broadway_cast_title_sweep_weekly',
      '11 14 * * 0',
      $cron$DO $cronbody$
      BEGIN
        IF NOT public.cron_should_fire('broadway_cast_title_sweep_weekly') THEN RETURN; END IF;
        PERFORM public._cron_invoke_edge_fn(
          'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/broadway-cast-collect',
          '{"mode":"discover"}'::jsonb
        );
      END $cronbody$;$cron$
    );
  END IF;
END $body$;

INSERT INTO public.cron_policy (
  jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, enabled, notes
) VALUES (
  'broadway_cast_title_sweep_weekly',
  '{}'::int[], 10080, 10080, 1, true,
  'Weekly Wikipedia title discovery for tracked Broadway shows missing a '
  'cast_wiki_title. Auto-sets high-confidence matches; logs the rest for a '
  'curator. Feeds the daily broadway_cast_collect poll.'
) ON CONFLICT (jobname) DO UPDATE SET
  notes = EXCLUDED.notes, enabled = EXCLUDED.enabled, daily_max_fires = EXCLUDED.daily_max_fires,
  updated_at = now();

-- ============================================================================
-- DONE.
-- ============================================================================
