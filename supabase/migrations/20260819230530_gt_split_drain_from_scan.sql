-- Migration 20260819230530 · level:data-collection · lane:D0 · writes:cron.schedule(gt_ingest_drain_1min)[new],cron.schedule(gt_deals_scan_odd_min)[new],cron.unschedule(gt_ingest_cascade_1min) · reads:gotickets_listings_snapshots,gt_listings_poll_state · pre:20260811280000 (cascade this replaces), 20260819213700 (gt_deals_retire_tick) · auth:OPERATOR-DIRECTED 2026-08-19 (incident mitigation)
-- INCIDENT FIX (2026-08-19 23:05) — a scan timeout rolls back the drain, stalling GoTickets ingest.
--
-- SYMPTOM. 7 of the last 12 gt_ingest_cascade_1min runs failed with "canceling statement due to
-- statement timeout" raised inside scan_gotickets_deals' _cand build. gt_listings_inflight grew
-- 4,575 (22:15) -> 11,250 (23:03) with the oldest unfulfilled request from 22:34; snapshot
-- freshness sawtooths instead of advancing.
--
-- ROOT CAUSE. The cascade runs drain -> median -> retire -> scan as ONE transaction. Mig
-- 20260811280000 wrapped the scan in `DO $b$ ... EXCEPTION WHEN OTHERS $b$` precisely so a scan
-- failure could not roll back the drain, but that wrapper does NOT hold for a statement-timeout
-- cancel: once the timeout fires, the cancel keeps re-firing through the handler's cleanup and
-- the ERROR propagates, aborting the whole transaction. So every scan timeout also discards that
-- tick's drained snapshots — the exact failure mode mig 280000 was written to prevent, reached by
-- a route the exception wrapper cannot cover. (Same reason a plpgsql handler can't make a
-- statement_timeout "recoverable": it is a cancel, not an ordinary error.)
--
-- FIX. Separate the transactions instead of trying to catch the cancel:
--   * gt_ingest_drain_1min  (* * * * *)   — drain + retire. Both are fast (retire measured at
--     34 ms on prod; drain is bounded at 3000 rows), so this job commits every minute and ingest
--     can no longer be rolled back by anything downstream.
--   * gt_deals_scan_odd_min (1-59/2)      — the event_median_price refresh + the scanner. If the
--     scan times out, only this job's work is lost. Odd minutes keep it off the saturated
--     :02/:05/:07 cluster marks (PR checklist) and off the drain's every-minute start.
-- The median refresh moves to the scan job deliberately: it is a percentile over a 12-minute
-- window of the 330M-row snapshots table, i.e. exactly the kind of statement that must not share
-- a transaction with the drain. It feeds the poller's value-gated cadence, not the drain.
--
-- NOT FIXED HERE. Why the scanner's _cand build exceeds its own 50s budget at all (it aggregates
-- 4h of gotickets_listings_snapshots every run) — that is the scanner rewrite, which is being
-- authored separately. This migration only stops that cost from taking ingest down with it.
--
-- Already applied to prod · via MCP 2026-08-19 23:07 UTC (operator-directed incident fix).
--   Result: cascade jobid 557 unscheduled; gt_ingest_drain_1min = jobid 565, gt_deals_scan_odd_min = jobid 566.
--
-- ROLLBACK:
--   SELECT cron.unschedule('gt_ingest_drain_1min');
--   SELECT cron.unschedule('gt_deals_scan_odd_min');
--   -- then re-create gt_ingest_cascade_1min with the mig 20260819213700 body.

DO $split$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname='gt_ingest_cascade_1min') THEN
    PERFORM cron.unschedule('gt_ingest_cascade_1min');
  END IF;
END
$split$;

-- 1. Ingest fast path — must commit every minute, no analysis work in this transaction.
SELECT cron.schedule('gt_ingest_drain_1min', '* * * * *', $cron$
  SELECT public.gt_listings_drain(3000);
  DO $b$ BEGIN PERFORM public.gt_deals_retire_tick(); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt retire skipped: %', SQLERRM; END $b$;
$cron$);

-- 2. Analysis path — median refresh + scanner. Failures here cost only this job.
SELECT cron.schedule('gt_deals_scan_odd_min', '1-59/2 * * * *', $cron$
  UPDATE public.gt_listings_poll_state ps SET event_median_price = m.med
    FROM (SELECT gt_event_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY all_in_price)::numeric AS med
          FROM public.gotickets_listings_snapshots
          WHERE captured_at > now()-interval '12 min' AND all_in_price > 0
          GROUP BY gt_event_id) m
    WHERE ps.gt_event_id = m.gt_event_id;
  DO $b$ BEGIN PERFORM public.scan_gotickets_deals(30); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt scan skipped: %', SQLERRM; END $b$;
$cron$);
