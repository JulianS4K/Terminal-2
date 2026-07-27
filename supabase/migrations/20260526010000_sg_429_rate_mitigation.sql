-- Migration: sg_429_rate_mitigation
-- Author: A1
-- Date: 2026-05-26
-- Description: Reduce SG 429 rate from ~58% average (CRITICAL — well above 15% alert
--   threshold). Root cause: 4 new 60d+ polling crons (added mig 20260520200000) each
--   fire 8 requests per 5-min slot, stacking with the existing priority pipeline and
--   exceeding SG's 10-req/8s token bucket during burst windows. Afternoon window
--   (UTC 17-19 / ET 1-4pm) shows 41-68% 429 rates; morning window is also affected.
--
--   Fix: reduce p_max_events from 8→4 in all 4 60d+ cron calls. Halves the per-slot
--   burst from these crons. Expected improvement: ~50% reduction in 429s from 60d+
--   crons → aggregate rate should drop from ~58% to target <20%.
--
--   Coverage impact: at 4 events/fire instead of 8, the full 60d+ cycle takes ~2 days
--   instead of ~1 day — acceptable for far-out events (no urgency on Sep/Oct games).
--
--   Monitor with: SELECT * FROM v_sg_broker_429_health ORDER BY hour_bucket DESC;
--   If pct_429 remains >20% after 24h, consider also pausing the afternoon window:
--     UPDATE cron_policy SET enabled = false WHERE jobname LIKE 'sg_60d%_afternoon';
--
-- Downstream: SG data pipeline (60d+ events get less frequent polling but no data loss)
-- Rollback: cron.schedule() with sg_broker_60d_plus_*_queue(8) — reverts to 8-batch

DO $outer$
BEGIN

  -- Morning listings (UTC 4-9 = ET 12am-5am EDT)
  PERFORM cron.schedule(
    'sg_60d_listings_morning',
    '1-59/5 4-9 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_60d_listings_morning') THEN RETURN; END IF;
      PERFORM public.sg_broker_60d_plus_listings_queue(4);
    END $cronbody$;$cron$
  );

  -- Morning sales (same window, 2-min offset)
  PERFORM cron.schedule(
    'sg_60d_sales_morning',
    '3-58/5 4-9 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_60d_sales_morning') THEN RETURN; END IF;
      PERFORM public.sg_broker_60d_plus_sales_queue(4);
    END $cronbody$;$cron$
  );

  -- Afternoon listings (UTC 17-19 = ET 1-3pm EDT)
  PERFORM cron.schedule(
    'sg_60d_listings_afternoon',
    '1-59/5 17-19 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_60d_listings_afternoon') THEN RETURN; END IF;
      PERFORM public.sg_broker_60d_plus_listings_queue(4);
    END $cronbody$;$cron$
  );

  -- Afternoon sales (same window, 2-min offset)
  PERFORM cron.schedule(
    'sg_60d_sales_afternoon',
    '3-58/5 17-19 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_60d_sales_afternoon') THEN RETURN; END IF;
      PERFORM public.sg_broker_60d_plus_sales_queue(4);
    END $cronbody$;$cron$
  );

END $outer$;
