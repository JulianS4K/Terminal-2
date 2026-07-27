-- Migration 20260518020000 · lane:A1 · writes:cron+cron_policy · reads:events,v_venue_neighbors · pre:20260518010000 · auth:operator-approved 2026-05-18
--
-- A1 PR-2 — re-schedule the existing refresh_event_competitors (mig 20260509350000).
-- The cron event_competitors_refresh_hourly was scheduled in 2026-05-09 and lost at some
-- point. refresh_event_competitors() TRUNCATEs + re-INSERTs from v_competing_events.
-- Sparse coverage is BY DESIGN — only events with venue neighbors within 20mi/24h get rows.

DO $body$ DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'event_competitors_refresh_hourly';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'event_competitors_refresh_hourly',
    '40 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('event_competitors_refresh_hourly') THEN RETURN; END IF;
      PERFORM public.refresh_event_competitors();
    END $cronbody$;$cron$
  );
END $body$;

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES (
  'event_competitors_refresh_hourly',
  '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
  60, 60, 24, true,
  'Re-schedule TRUNCATE+rebuild from v_competing_events (was scheduled in mig 20260509350000, unscheduled at some point). Sparse coverage by-design — only events with 20mi/24h venue neighbors.'
) ON CONFLICT (jobname) DO UPDATE SET enabled = true, updated_at = now();
