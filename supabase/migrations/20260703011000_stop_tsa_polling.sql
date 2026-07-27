-- ============================================================================
-- Migration 20260703011000 — stop polling TSA throughput
--
-- Lane:     A1 data plane
-- Touches:  cron (unschedule tsa_queue_daily / tsa_process_5min / tsa_sweep_daily)
-- Pre-reqs: 20260702235500 (which scheduled them)
--
-- WHY (operator directive 2026-07-03): the TSA feed is national-only (a single
--   daily nationwide checkpoint total — tsa.gov publishes no per-airport daily
--   breakdown), so as a per-event/per-performer signal its marginal value is low.
--   Stop the daily pull. The already-ingested rows + the tsa_queue/process/sweep
--   functions + the macro_indicators series are LEFT IN PLACE (reversible — just
--   re-schedule to resume). The terminal TSA readout self-hides once the data
--   goes stale (FE freshness guard), so no frozen number lingers on the pages.
-- ============================================================================

SELECT cron.unschedule('tsa_queue_daily')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tsa_queue_daily');
SELECT cron.unschedule('tsa_process_5min')  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tsa_process_5min');
SELECT cron.unschedule('tsa_sweep_daily')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tsa_sweep_daily');
