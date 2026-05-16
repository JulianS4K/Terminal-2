-- Migration 20260516020000 · admin · align sg_broker backstop queue schedules · pre:20260516010000
-- D2 diagnostic 2026-05-16 surfaced the coupled-polling question: priority tick already
-- does coupled sales+listings for HOT/WARM/COOL events (sg_priority_poll_tick fires both
-- endpoints in same minute). The two backstop queues (sg_broker_listings_queue_30min,
-- sg_broker_sales_queue_30min) are deliberately asymmetric in event SELECTION (listings =
-- broad firehose by date; sales = priority-weighted by ownership), but their fire MINUTE
-- was offset for no design reason: listings :04/:34, sales :02/:32.
--
-- Aligning sales to :04/:34 gives the 32% overlap subset (~80 events per cycle) co-temporal
-- sales+listings snapshots, useful for sale-vs-remaining-inventory deltas. Same total API
-- volume (no event count change), just bursts together. pg_net batch_size=200 absorbs the
-- 50→100 same-minute calls trivially.

SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname='sg_broker_sales_queue_30min'),
  schedule := '4,34 * * * *'
);
