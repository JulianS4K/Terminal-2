-- Migration 20260901162620 · level:admin · lane:A1 · operator-directed 2026-09-01
--   ("pause X_news for now" -> follow-up once the real 402 source was identified).
--
--   writes: cron.job (watchlist_social_poll_1min -> inactive)
--   reads:  cron.job
--
-- WHY. This is the actual source of the one-per-minute HTTP 402
-- {"error":"Unauthorized","message":"Credits is not enough.Please recharge"}.
--
-- The preceding migration (20260901161819) paused x_news_queue_1min /
-- x_news_process_1min on the theory that they produced it. They did not: the 402s
-- continued unchanged at exactly one per minute at 16:19, 16:20, 16:21 and 16:22,
-- after that pause took effect at 16:18. That migration's own attribution caveat
-- called for checking the remaining '* * * * *' pg_net callers, which is what
-- found this.
--
-- api.twitterapi.io has TWO callers in this database:
--   * x_news_queue            -- paused in 20260901161819
--   * watchlist_social_poll   -- this one, driven by watchlist_social_poll_1min
--
-- watchlist_social_poll(p_limit => 1) processes ONE watchlisted athlete per run and
-- issues exactly two requests: a free old.reddit.com RSS search, and an
-- api.twitterapi.io advanced search. One Twitter call per minute, which is precisely
-- the observed 402 rate.
--
-- TRADE-OFF, put to the operator and accepted. There is a narrower fix: the Twitter
-- call is already guarded by IF v_key IS NOT NULL AND btrim(v_key) <> '', so clearing
-- the TWITTERAPI_IO_KEY vault secret would disable the Twitter branch in BOTH callers
-- while leaving this job's working Reddit half running. The operator chose to pause
-- the whole job instead, which also stops the Reddit RSS search and takes
-- player_watchlist social signal dark. Recorded here so the cost is not rediscovered
-- later as a mystery.
--
-- Unaffected: broadway_social_poll_2min still polls old.reddit.com on its own
-- schedule; reddit_news_queue_1min / reddit_news_process_1min were already inactive.
--
-- Paused, not unscheduled -- re-enabling is one alter_job once twitterapi.io credits
-- are restored, or immediately if only the Reddit half is wanted back.

DO $pause$
DECLARE v_id bigint;
BEGIN
  SELECT jobid INTO v_id FROM cron.job WHERE jobname = 'watchlist_social_poll_1min';
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'watchlist_social_poll_1min not found';
  END IF;
  PERFORM cron.alter_job(job_id := v_id, active := false);
  RAISE NOTICE 'paused watchlist_social_poll_1min';
END $pause$;

DO $verify$
DECLARE v_active text;
BEGIN
  SELECT string_agg(jobname, ', ') INTO v_active
    FROM cron.job
   WHERE active AND jobname IN ('watchlist_social_poll_1min','x_news_queue_1min','x_news_process_1min');
  IF v_active IS NOT NULL THEN
    RAISE EXCEPTION 'expected all twitterapi.io callers inactive, still active: %', v_active;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'watchlist_social_poll_1min') THEN
    RAISE EXCEPTION 'watchlist_social_poll_1min missing -- expected paused, not unscheduled';
  END IF;
END $verify$;
