-- Migration 20260811263000 · lane:D0 · operator-directed 2026-08-11
--   ("cascade the run to keep feed fresh").
--
--   writes: cron — replace gt_listings_drain_1min + gotickets_deals_scan_5min with a single
--           1-minute cascade gt_ingest_cascade_1min that drains THEN scans in sequence.
--
-- WHY. The pipeline was three independent crons: poll (2m) → drain (1m) → scan→feed (5m).
-- A fresh listing could sit up to ~5 min before the scanner turned it into a feed deal, and
-- the separate drain/scan crons could race at the same minute mark. Cascade drain→scan in one
-- 1-minute job so the scanner always runs on freshly-drained data and a new deal reaches the
-- feed within ~1-2 min of its poll. (Poll stays a separate 2-min cron: it fires async
-- net.http_get requests whose responses only land seconds later, so it can't share the same
-- synchronous cascade — the cascade processes whatever responses have arrived.)
-- Scan batch bumped 20→30 (freshest-cap-first; only tevo-mapped events feed the scanner, a
-- small set, so 30/min keeps the mapped hot events fresh well within the 55s budget).
--
-- ROLLBACK:
--   SELECT cron.unschedule('gt_ingest_cascade_1min');
--   SELECT cron.schedule('gt_listings_drain_1min','* * * * *',$$SELECT public.gt_listings_drain(3000);$$);
--   SELECT cron.schedule('gotickets_deals_scan_5min','*/5 * * * *',$$SELECT public.scan_gotickets_deals(20);$$);

DO $cascade$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname='gt_listings_drain_1min') THEN
    PERFORM cron.unschedule('gt_listings_drain_1min');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname='gotickets_deals_scan_5min') THEN
    PERFORM cron.unschedule('gotickets_deals_scan_5min');
  END IF;
END
$cascade$;

SELECT cron.schedule('gt_ingest_cascade_1min', '* * * * *',
  $$SELECT public.gt_listings_drain(3000); SELECT public.scan_gotickets_deals(30);$$);
