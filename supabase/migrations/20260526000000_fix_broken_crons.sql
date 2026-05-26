-- Migration: fix_broken_crons
-- Author: A1
-- Date: 2026-05-26
-- Description: Fix 3 broken crons that fail every run:
--   midnight-catchup-sweep (SELECT→PERFORM),
--   weather_climatology_weekly (2x SELECT→PERFORM),
--   listings_aq_backfill_overnight (chunk size 100→25 + 3min timeout)
-- Downstream: none
-- Rollback: cron.schedule() with original body

-- ============================================================
-- 1. midnight-catchup-sweep — SELECT → PERFORM in DO block
--    Root: midnight_catchup_sweep() returns rows; SELECT inside a DO block
--          requires an INTO target or must be PERFORM.
--    Schedule: 0 8 * * * (rescheduled from 0 0 * * * in 20260513185058)
-- ============================================================
SELECT cron.schedule(
  'midnight-catchup-sweep',
  '0 8 * * *',
  $cmd$DO $body$ BEGIN IF NOT public.cron_should_fire('midnight-catchup-sweep') THEN RETURN; END IF; SET LOCAL statement_timeout = '5min'; PERFORM public.midnight_catchup_sweep(); END $body$;$cmd$
);

-- ============================================================
-- 2. weather_climatology_weekly — 2× SELECT → PERFORM in DO block
--    Root: weather_historical_backfill_outdoor() and weather_historical_process()
--          return rows; SELECT inside a DO block requires INTO or PERFORM.
--    Schedule: 0 6 * * 0 (unchanged)
-- ============================================================
SELECT cron.schedule(
  'weather_climatology_weekly',
  '0 6 * * 0',
  $cmd$DO $body$ BEGIN PERFORM weather_historical_retry_throttled(20); PERFORM weather_historical_backfill_outdoor((current_date - interval '3 years')::date, (current_date - interval '1 day')::date, 10); PERFORM weather_historical_process(); END $body$;$cmd$
);

-- ============================================================
-- 3. listings_aq_backfill_overnight — chunk 100 → 25 + 3min timeout
--    Root: match_unmatched_listings_chunked(100, true) consistently exceeds
--          the default 120s statement timeout. Smaller chunk + explicit timeout
--          lets each firing complete within its cron slot.
--    Schedule: 2-14 4 * * * (unchanged)
-- ============================================================
SELECT cron.schedule(
  'listings_aq_backfill_overnight',
  '2-14 4 * * *',
  $cmd$DO $$ DECLARE v_remaining int; BEGIN SET LOCAL statement_timeout = '3min'; SELECT max(events_remaining) INTO v_remaining FROM public.match_unmatched_listings_chunked(25, true); IF coalesce(v_remaining, 0) = 0 THEN PERFORM cron.unschedule('listings_aq_backfill_overnight'); END IF; END $$;$cmd$
);
