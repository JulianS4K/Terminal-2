-- Migration 20260518010000 · lane:A1 · writes:cron+cron_policy · reads:event_metrics,event_lifecycle · pre:20260517260000 · auth:operator-approved 2026-05-18
--
-- A1 PR-1 — schedule the existing backfill_event_sentiment (from mig 20260509130000).
-- Functions live on prod, never called. 30-min cadence — sentiment is delta-driven,
-- so faster cadence captures velocity changes mid-day.

DO $body$ DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'event_sentiment_compute_30min';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'event_sentiment_compute_30min',
    '15,45 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('event_sentiment_compute_30min') THEN RETURN; END IF;
      PERFORM public.backfill_event_sentiment(200);
    END $cronbody$;$cron$
  );
END $body$;

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES (
  'event_sentiment_compute_30min',
  '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
  30, 30, 48, true,
  'Schedule existing backfill_event_sentiment (mig 20260509130000). Reads 2 event_metrics snapshots per event, computes sentiment_index + velocity signals. NULL-safe on missing prior snapshots (function returns NULL if no 6-36h-old prior).'
) ON CONFLICT (jobname) DO UPDATE SET enabled = true, updated_at = now();
