-- Migration 20260901161819 · level:admin · lane:A1 · operator-directed 2026-09-01
--   ("pause X_news for now").
--
--   writes: cron.job (x_news_queue_1min, x_news_process_1min -> inactive)
--   reads:  cron.job
--
-- WHY. The X news pipeline is polling a paid upstream that has run out of credits,
-- once a minute, and has been storing nothing.
--
-- Measured 2026-09-01 16:05-16:20 UTC:
--   * Exactly ONE HTTP 402 per minute, every minute, in net._http_response --
--     {"error":"Unauthorized","message":"Credits is not enough.Please recharge"}.
--     43 in the 14:00 hour, 59 in the 15:00 hour, 16 in the first sixteen minutes
--     of 16:00. The one-per-minute cadence matches a '* * * * *' job.
--   * public.x_news holds 0 rows. x_news_pending holds 5,028 rows of which 2,308
--     are unresolved.
--   * x_news_process_1min has failed 3,843 of 4,806 runs (80%) over the eight days
--     of cron.job_run_details retention, averaging 135s per run against a 120s
--     statement_timeout -- i.e. most runs burn the timeout and roll back.
--
-- ATTRIBUTION CAVEAT. The 402 responses could not be tied to a URL with certainty:
-- net.http_request_queue is drained when a response lands, and the response headers
-- show only Cloudflare. The identification rests on the one-per-minute cadence
-- lining up with these two jobs plus the empty x_news table. If a 402-per-minute
-- persists after this migration, the source is something else and this pause was
-- aimed at the wrong pipeline -- check the remaining '* * * * *' pg_net callers.
--
-- PRECEDENT. Branch migration 20260831160000 paused this same pair for the same
-- reason on 2026-08-31. The 2026-09-01 rollback to e43d549 restored them because
-- they appear in the pre-branch restore manifest -- a faithful rollback, but it
-- reinstated a known-dead poller. This migration re-applies the pause deliberately.
--
-- NOT DONE HERE. No retention policy is touched: x_news is empty, and the
-- reddit_news / x_news retention rows already sit at priority 100 where the
-- rollback left them. Whether the upstream credits are worth recharging is an
-- operator decision; this only stops the pointless per-minute call.

DO $pause$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT jobid, jobname FROM cron.job
     WHERE jobname IN ('x_news_queue_1min','x_news_process_1min') AND active
  LOOP
    PERFORM cron.alter_job(job_id := r.jobid, active := false);
    n := n + 1;
    RAISE NOTICE 'paused %', r.jobname;
  END LOOP;
  RAISE NOTICE 'paused % x_news job(s)', n;
END $pause$;

DO $verify$
DECLARE v_active text;
BEGIN
  SELECT string_agg(jobname, ', ') INTO v_active
    FROM cron.job
   WHERE active AND jobname IN ('x_news_queue_1min','x_news_process_1min');
  IF v_active IS NOT NULL THEN
    RAISE EXCEPTION 'x_news job(s) still active: %', v_active;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'x_news_queue_1min') THEN
    RAISE EXCEPTION 'x_news_queue_1min missing entirely -- expected paused, not unscheduled';
  END IF;
END $verify$;
