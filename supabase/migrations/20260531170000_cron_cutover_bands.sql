-- ============================================================
-- MIG-E/F — cron cutover to the band-driven per-event pollers.
-- A1 2026-05-31 (cadence redesign Part A5/B). Operator-approved.
--
-- Retires the 6 EVO windowed collectors + featured override, the 3 overlapping SG
-- listings pollers (blindspot/floor/60d) + the 2 SG sales-queue/60d pollers, and the
-- ~9 already-inactive SG crons. Schedules evo_listings_poll_2min + sg_listings_poll_2min
-- (staggered even/odd minute). sg_sales_poll_5min (248) is KEPT — it already calls the
-- now-retuned sg_sales_poll_tick. New ticks treat NULL/old last_polled as due → automatic
-- backfill. Kill switch: UPDATE cron_policy SET enabled=false WHERE jobname=...
-- ============================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, enabled, notes) VALUES
  ('evo_listings_poll_2min', ARRAY[12,13,14,15,16,17,18,19,20,21,22,23], 2, 2, NULL, 800, true,
   'EVO per-event listings scan; per-event horizon interval enforced in-tick via collector_band'),
  ('sg_listings_poll_2min',  ARRAY[12,13,14,15,16,17,18,19,20,21,22,23], 2, 2, NULL, 800, true,
   'SG band-driven listings scan; rate-aware backoff + strand-safe advance-on-200')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  daily_max_fires = EXCLUDED.daily_max_fires,
  enabled = EXCLUDED.enabled, updated_at = now();

-- Retire old collectors + inactive cruft (idempotent; ignore "job not found").
DO $unsched$
DECLARE j text;
BEGIN
  FOREACH j IN ARRAY ARRAY[
    'collect-listings-0-24h','collect-listings-1-7d','collect-listings-7-30d',
    'collect-listings-30-60d','collect-listings-60d+','collect-listings-featured-10min',
    'sg_blindspot_poll_5min','sg_listings_floor_sweep',
    'sg_60d_listings_morning','sg_60d_listings_afternoon',
    'sg_broker_sales_queue_5min','sg_60d_sales_morning','sg_60d_sales_afternoon',
    'sg_broker_listings_queue_5min','sg_broker_listings_queue_5min_peak','sg_priority_poll_tick_5min',
    'sg_listings_0-24h','sg_listings_1-7d','sg_listings_7-30d','sg_listings_30-60d','sg_listings_60d+',
    'sg_listings_process_5min'
  ] LOOP
    BEGIN PERFORM cron.unschedule(j); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $unsched$;

-- Schedule the new per-event pollers (staggered: EVO even minutes, SG odd minutes).
SELECT cron.schedule('evo_listings_poll_2min', '*/2 * * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('evo_listings_poll_2min') THEN RETURN; END IF; PERFORM public.evo_listings_poll_tick(50); END $b$;$cron$);
-- p_max=5: SG broker /listings is a ~5-req-per-10s window; firing >5 in one tight tick
-- overruns the window (the rest 429). 5/tick fits one window → minimal waste. Strand-fix
-- re-queues any 429'd event for the next tick.
SELECT cron.schedule('sg_listings_poll_2min', '1-59/2 * * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_listings_poll_2min') THEN RETURN; END IF; PERFORM public.sg_listings_poll_tick(5); END $b$;$cron$);
