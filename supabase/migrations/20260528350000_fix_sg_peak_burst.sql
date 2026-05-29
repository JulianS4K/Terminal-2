-- Fix: sg_broker_listings_queue_5min_peak burst 25 → 8
-- Root cause: peak cron fires 16:00–03:59 UTC with burst=25 events/call.
-- At 16:00 UTC total_fired jumps from ~100/hr → 692/hr (vs SG's ~10 token/8s bucket).
-- All 25 async pg_net requests dispatch simultaneously → 15 immediately get 429'd.
-- SG listings 429 rate has been 78–81% every hour since 16:00 UTC 2026-05-28.
-- Fix: reduce burst to 8 (matching the safe limit from mig 20260519140000).
-- Expected: total_fired/hr drops from 692 → ~192; pct_429 should return to <15%.
-- Authored by D0 2026-05-28 after audit. A1 to review + apply.

SELECT cron.unschedule('sg_broker_listings_queue_5min_peak');

SELECT cron.schedule(
  'sg_broker_listings_queue_5min_peak',
  '*/5 16-23,0-3 * * *',
  $cronbody$
    DO $b$ BEGIN
      IF NOT public.cron_should_fire('sg_broker_listings_queue_5min_peak') THEN RETURN; END IF;
      PERFORM public.sg_broker_listings_queue(8);
    END $b$;
  $cronbody$
);

-- Verify
SELECT jobname, schedule, command
FROM cron.job
WHERE jobname = 'sg_broker_listings_queue_5min_peak';
