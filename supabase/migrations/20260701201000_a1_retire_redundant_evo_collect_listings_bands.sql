-- ============================================================================
-- Migration 20260701201000 — retire redundant EVO collect-listings band crons
--
-- Lane:     A1
-- Touches:  cron jobs collect-listings-{0-24h,1-7d,7-30d,30-60d,60d+} -> active=false.
-- Pre-reqs: evo_listings_poll_2min (per-event cadence poller, collector_cadence).
--
-- WHY (wholesale EVO review, operator 2026-07-01 "retire redundant EVO band crons"):
--   EVO listings were being DOUBLE-collected: (1) evo_listings_poll_2min polls every future
--   event per-event on its collector_cadence band (≤3d 5m … 180d+ 24h, ~7,394 events), and
--   (2) these 5 collect-listings-<window> crons POSTed to the collect-listings edge fn with
--   ?window=<horizon> to refresh ALL events in that horizon on a fixed schedule. (2) is fully
--   subsumed by (1) — same edge fn, same events, same listings_snapshots target — so it only
--   duplicated edge-fn invocations + snapshot writes. Retire the 5 band crons.
--
--   KEPT ACTIVE: collect-listings-discover-* (distinct purpose — they DISCOVER new events not
--   yet in `events`, which the per-event poller does not do). EVO is the free TEvo firehose, so
--   this is a compute/write-dedup cleanup, not a credit saving.
--
-- Idempotent: cron.alter_job by name. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

DO $do$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT jobid FROM cron.job
           WHERE jobname IN ('collect-listings-0-24h','collect-listings-1-7d','collect-listings-7-30d',
                             'collect-listings-30-60d','collect-listings-60d+')
  LOOP
    PERFORM cron.alter_job(r.jobid, active:=false);
  END LOOP;
END $do$;
