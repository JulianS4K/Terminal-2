-- 20260527220000_evo_listing_cadence_discovery.sql
--
-- EVO collect-listings cadence overhaul:
--
-- 0-24h:  NO CHANGE — keeps 1-59/10 (every 10 min all hours, 144 fires/day)
--
-- 1-7d:   CONSOLIDATED — replaces twice-daily baseline (30 5,17) + 30-min peak
--         (*/30 16-23,0-3) with a single */10 all-hours cron.
--         min_age_seconds=540 gates re-pulls, keeping actual TEvo API calls
--         roughly equal to the old 30-min cron (~3,500-4,600/day).
--
-- 7-30d:  2×/day (20 4,16) → 3×/day (5 13,19,3) — aligned with snapshot times.
-- 30-60d: 2×/day (35 4,16) → 3×/day (10 13,19,3) — staggered 5 min from 7-30d.
-- 60d+:   2×/day (50 4,16) → 3×/day (15 13,19,3) — staggered 10 min from 7-30d.
--
-- Timing rationale (outer windows):
--   TD fires SH at 13:00/19:00/3:00 UTC.
--   Outer windows fire 5/10/15 min later → fresh before snapshot crons at :30.
--
-- EVO discovery stub (Phase 1):
--   evo_discover_new_events() — queries local DB to report EVO coverage stats.
--   No TEvo API calls in Phase 1 (safe stub, no rate limit risk).
--   Phase 2 will add net.http_get to /v9/events for new-event discovery.
--   Cron: 0 8 * * * (8am UTC = 4am ET, daily).
--
-- Resource audit: 116 active crons pre-migration. Adding 1-7d at */10 matches
-- existing 0-24h cadence. Instance already handles 9 jobs at 10-min cadence.

-- ── 1. collect-listings-1-7d: consolidate to single 10-min all-day cron ──────

DO $sched$ BEGIN

  -- Remove old twice-daily baseline (30 5,17 UTC)
  PERFORM cron.unschedule('collect-listings-1-7d');

  -- Remove old 30-min peak cron (*/30 16-23,0-3, added 20260527190000)
  PERFORM cron.unschedule('collect-listings-1-7d-peak');

  -- Single 10-min all-hours cron — matches 0-24h cadence
  -- min_age_seconds=540 (9 min): edge fn skips events collected within last 9 min
  PERFORM cron.schedule(
    'collect-listings-1-7d',
    '*/10 * * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('collect-listings-1-7d') THEN RETURN; END IF;
      PERFORM public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=1-7d&min_age_seconds=540',
        '{}'::jsonb);
    END $b$;$cron$
  );

-- ── 2. Outer windows: 2×/day → 3×/day, aligned with snapshot times ───────────

  -- 7-30d: was 20 4,16 UTC — now fires 5 min after TD SH, 25 min before snapshot
  PERFORM cron.schedule(
    'collect-listings-7-30d',
    '5 13,19,3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('collect-listings-7-30d') THEN RETURN; END IF;
      PERFORM public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=7-30d',
        '{}'::jsonb);
    END $b$;$cron$
  );

  -- 30-60d: staggered 5 min after 7-30d
  PERFORM cron.schedule(
    'collect-listings-30-60d',
    '10 13,19,3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('collect-listings-30-60d') THEN RETURN; END IF;
      PERFORM public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=30-60d',
        '{}'::jsonb);
    END $b$;$cron$
  );

  -- 60d+: staggered 10 min after 7-30d
  PERFORM cron.schedule(
    'collect-listings-60d+',
    '15 13,19,3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('collect-listings-60d+') THEN RETURN; END IF;
      PERFORM public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=60d%2B',
        '{}'::jsonb);
    END $b$;$cron$
  );

-- ── 3. EVO discovery stub cron ────────────────────────────────────────────────

  PERFORM cron.schedule(
    'evo_discover_new_events',
    '0 8 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('evo_discover_new_events') THEN RETURN; END IF;
      PERFORM public.evo_discover_new_events();
    END $b$;$cron$
  );

END $sched$;

-- ── 4. cron_policy updates ────────────────────────────────────────────────────

-- Remove stale policy for peak cron (unscheduled above)
DELETE FROM public.cron_policy WHERE jobname = 'collect-listings-1-7d-peak';

-- Update 1-7d: now all-day 10-min, matches 0-24h cadence
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, work_check_sql, enabled, notes)
VALUES
  ('collect-listings-1-7d',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23]::int[], 9, 9, 150,
   'SELECT true', true,
   'EVO 1-7d collect-listings every 10 min all hours (*/10 * * * *). '
   'Supersedes twice-daily + 30-min-peak pattern. '
   'min_age_seconds=540 gates re-pulls — actual TEvo calls/day ~same as 30-min cron. '
   'Activated 2026-05-27.')
ON CONFLICT (jobname) DO UPDATE
  SET peak_min_interval_min    = 9,
      offpeak_min_interval_min = 9,
      daily_max_fires          = 150,
      notes                    = EXCLUDED.notes,
      enabled                  = true,
      updated_at               = now();

-- Update outer windows: now 3×/day at snapshot-aligned times
UPDATE public.cron_policy SET
  peak_min_interval_min    = 359,
  offpeak_min_interval_min = 359,
  daily_max_fires          = 3,
  notes = 'EVO 7-30d collect-listings 3×/day: 13:05/19:05/3:05 UTC. '
          'Aligned with TD SH fires (13:00/19:00/3:00) +5min. '
          'Snapshots fire at :30 — outer windows are fresh by snapshot time. '
          'Upgraded from 2×/day (20 4,16) on 2026-05-27.',
  updated_at = now()
WHERE jobname = 'collect-listings-7-30d';

UPDATE public.cron_policy SET
  peak_min_interval_min    = 359,
  offpeak_min_interval_min = 359,
  daily_max_fires          = 3,
  notes = 'EVO 30-60d collect-listings 3×/day: 13:10/19:10/3:10 UTC. '
          'Staggered 5 min after 7-30d to avoid concurrent edge fn invocations. '
          'Upgraded from 2×/day (35 4,16) on 2026-05-27.',
  updated_at = now()
WHERE jobname = 'collect-listings-30-60d';

UPDATE public.cron_policy SET
  peak_min_interval_min    = 359,
  offpeak_min_interval_min = 359,
  daily_max_fires          = 3,
  notes = 'EVO 60d+ collect-listings 3×/day: 13:15/19:15/3:15 UTC. '
          'Staggered 10 min after 7-30d. '
          'Upgraded from 2×/day (50 4,16) on 2026-05-27.',
  updated_at = now()
WHERE jobname = 'collect-listings-60d+';

-- ── 5. EVO discovery function (Phase 1 stub) ─────────────────────────────────

CREATE OR REPLACE FUNCTION public.evo_discover_new_events()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_total_sgc         int;
  v_mapped_sgc        int;
  v_with_metrics_30d  int;
  v_future_unmapped   int;
BEGIN
  -- Phase 1 stub: compute local EVO coverage stats, log to bot_chat.
  -- No TEvo API calls — safe stub with no rate limit risk.
  -- Phase 2 will add net.http_get to /v9/events for new-event discovery.

  -- Total upcoming events in sg_events_canonical (next 90 days)
  SELECT COUNT(*) INTO v_total_sgc
  FROM public.sg_events_canonical
  WHERE sg_datetime_utc BETWEEN now() AND now() + interval '90 days';

  -- Events that are mapped to aq_event_map (have TEvo event_id linkage)
  SELECT COUNT(DISTINCT sgc.sg_event_id) INTO v_mapped_sgc
  FROM public.sg_events_canonical sgc
  JOIN public.aq_event_map aem ON aem.sg_event_id = sgc.sg_event_id
  WHERE sgc.sg_datetime_utc BETWEEN now() AND now() + interval '90 days';

  -- Events in 1-30d window that have recent event_metrics data
  SELECT COUNT(DISTINCT em.event_id) INTO v_with_metrics_30d
  FROM public.event_metrics em
  JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = em.event_id
  WHERE sgc.sg_datetime_utc BETWEEN now() AND now() + interval '30 days'
    AND em.captured_at > now() - interval '24 hours';

  -- SG events in next 30d NOT yet in aq_event_map (potential discovery targets)
  SELECT COUNT(*) INTO v_future_unmapped
  FROM public.sg_events_canonical sgc
  LEFT JOIN public.aq_event_map aem ON aem.sg_event_id = sgc.sg_event_id
  WHERE sgc.sg_datetime_utc BETWEEN now() AND now() + interval '30 days'
    AND aem.sg_event_id IS NULL;

  PERFORM public.bot_chat_log(
    'status',
    'evo_discover_new_events',
    format(
      'EVO coverage report (Phase 1 stub — 8am UTC daily). '
      'Next 90d SG events: %s total, %s mapped to TEvo (%s%%mapped). '
      'Next 30d with recent metrics: %s events. '
      'Next 30d unmapped SG events (discovery targets): %s. '
      'Phase 2: add net.http_get to TEvo /v9/events for new-event ingestion.',
      v_total_sgc,
      v_mapped_sgc,
      CASE WHEN v_total_sgc > 0
        THEN ROUND(100.0 * v_mapped_sgc / v_total_sgc, 1)::text
        ELSE '0' END,
      v_with_metrics_30d,
      v_future_unmapped
    ),
    NULL,
    'D0'
  );
END $$;
REVOKE ALL ON FUNCTION public.evo_discover_new_events() FROM anon, public;
COMMENT ON FUNCTION public.evo_discover_new_events() IS
  'Phase 1 stub: compute EVO coverage stats from local DB, log to bot_chat. '
  'Runs daily at 8am UTC (4am ET). No external API calls. '
  'Phase 2 will add TEvo /v9/events HTTP discovery + aq_event_map writes.';

-- cron_policy for discovery
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, work_check_sql, enabled, notes)
VALUES
  ('evo_discover_new_events',
   ARRAY[]::int[], 1440, 1440, 1, 'SELECT true', true,
   'Daily EVO coverage report (Phase 1 stub): logs SG→TEvo mapping stats to bot_chat. '
   'Runs at 8am UTC = 4am ET. Phase 2: add TEvo /v9/events new-event ingestion.')
ON CONFLICT (jobname) DO UPDATE
  SET notes = EXCLUDED.notes, enabled = true, updated_at = now();
