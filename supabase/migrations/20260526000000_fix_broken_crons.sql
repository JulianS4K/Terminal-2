-- Migration: fix_broken_crons
-- Author: A1
-- Date: 2026-05-26
-- Description: Fix 3 crons that have never succeeded:
--   (1) midnight-catchup-sweep: SELECT public.midnight_catchup_sweep() inside a DO block
--       has no destination → "query has no destination for result data". Fix: PERFORM.
--   (2) weather_climatology_weekly: two SELECT fn() calls inside DO block have no
--       destination. Fix: PERFORM both. The first call already uses PERFORM (correct);
--       the two SELECTs that follow need the same treatment.
--   (3) listings_aq_backfill_overnight: match_unmatched_listings_chunked(100, true)
--       always hits the default 120s statement_timeout. Fix: SET LOCAL to 3min + reduce
--       chunk from 100→25 so each call completes within the window.
-- Downstream: data pipelines (weather backfill, listings AQ xref, midnight catchup) now run
-- Rollback: cron.schedule() with the original bodies (see comments below each fix)
-- Depends on: cron.job entries for all 3 jobnames existing (shipped in prior migrations)

DO $outer$
BEGIN

  -- ----------------------------------------------------------------
  -- FIX 1: midnight-catchup-sweep
  -- Original body used SELECT public.midnight_catchup_sweep() inside a
  -- DO block — functions returning rows need PERFORM in PL/pgSQL.
  -- ----------------------------------------------------------------
  PERFORM cron.schedule(
    'midnight-catchup-sweep',
    '20 3 * * *',
    $cron$DO $body$
BEGIN
  IF NOT public.cron_should_fire('midnight-catchup-sweep') THEN RETURN; END IF;
  SET LOCAL statement_timeout = '5min';
  PERFORM public.midnight_catchup_sweep();
END $body$;$cron$
  );

  -- ----------------------------------------------------------------
  -- FIX 2: weather_climatology_weekly
  -- Original body: PERFORM on first call (correct), then two bare SELECTs
  -- inside the DO block that have no INTO destination → syntax error.
  -- Fix: change both SELECT calls to PERFORM.
  -- ----------------------------------------------------------------
  PERFORM cron.schedule(
    'weather_climatology_weekly',
    '0 4 * * 0',
    $cron$DO $body$
BEGIN
  IF NOT public.cron_should_fire('weather_climatology_weekly') THEN RETURN; END IF;
  PERFORM weather_historical_retry_throttled(20);
  PERFORM weather_historical_backfill_outdoor(
    (current_date - interval '3 years')::date,
    (current_date - interval '1 day')::date,
    10);
  PERFORM weather_historical_process();
END $body$;$cron$
  );

  -- ----------------------------------------------------------------
  -- FIX 3: listings_aq_backfill_overnight
  -- match_unmatched_listings_chunked(100, true) always exceeds the
  -- default 120s cron statement timeout. Two changes:
  --   (a) SET LOCAL statement_timeout = '3min' to give it headroom
  --   (b) Reduce chunk from 100→25 so each invocation is faster
  -- The cron unschedules itself when events_remaining = 0 (preserved).
  -- ----------------------------------------------------------------
  PERFORM cron.schedule(
    'listings_aq_backfill_overnight',
    '2-14 4 * * *',
    $cron$
DO $body$
DECLARE v_remaining int;
BEGIN
  SET LOCAL statement_timeout = '3min';
  SELECT max(events_remaining) INTO v_remaining
  FROM public.match_unmatched_listings_chunked(25, true);
  IF coalesce(v_remaining, 0) = 0 THEN
    PERFORM cron.unschedule('listings_aq_backfill_overnight');
  END IF;
END $body$;
$cron$
  );

END $outer$;
