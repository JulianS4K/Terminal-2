-- Migration 20261125183000 · level:data-collection · lane:A1 (data plane — crons) · writes:cron.job · reads:cron.job · pre:20261125180000
--
-- Stop the Reddit news pollers (operator 2026-11-25).
--
-- reddit_news_queue_1min (SELECT reddit_news_queue(1)) fetched Reddit news every minute and
-- reddit_news_process_1min drained what it queued. The anonymous Reddit feeds have been 403-ing,
-- so the pair did ~1.9 backend-hours/day of work that produced nothing, on a disk-bound database.
-- Both were unscheduled live on prod on 2026-11-25; this records that so a from-scratch replay
-- does not recreate them. Idempotent: it only unschedules a job that is still present.
--
-- To bring the feed back, reschedule both jobs (and set up an authenticated Reddit API app so the
-- fetches stop 403-ing). The reddit_news_queue()/reddit_news_process() functions are left in place.

DO $$ BEGIN
  PERFORM cron.unschedule('reddit_news_queue_1min')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_news_queue_1min');
  PERFORM cron.unschedule('reddit_news_process_1min')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_news_process_1min');
END $$;

-- VERIFY: SELECT count(*) FROM cron.job WHERE jobname IN ('reddit_news_queue_1min','reddit_news_process_1min');  -- 0
-- ROLLBACK: re-apply the migrations that scheduled reddit_news_queue_1min / reddit_news_process_1min.
