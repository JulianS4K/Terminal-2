-- Migration 20261006200000 · level:data-collection · lane:A1 (operator-routed to D0, "fix reddit feed") · writes:reddit_news_queue(),broadway_social_poll(),cron.job,reddit_news_pending · reads:reddit_news_flairs,broadway_show_ref,net._http_response · pre:20260714210000,20260714250000
--
-- ============================================================================
-- Migration 20261006200000 — Reddit news wire: www.reddit.com host + resume
--
-- Lane:     A1 data plane (reddit ingest), operator-routed 2026-10-06 ("also fix
--           reddit feed"); broadway_social_poll is D3's poller on the same
--           pipeline — same one-line host change, coordinated in the PR.
-- Touches:  reddit_news_queue (W), broadway_social_poll (W), cron.job active
--           (446 reddit_news_process_1min, 449 reddit_news_queue_1min),
--           reddit_news_pending (W: close orphaned rows)
-- Pre-reqs: 20260714210000 (reddit_news_queue keyword branch),
--           20260714250000 (broadway_social_poll)
--
-- Already applied to prod · via MCP 2026-10-06 18:35 UTC under operator direction
-- ("also fix reddit feed"). First cycle 18:37–18:38: www.reddit.com 200s,
-- reddit_news 0 → 50 rows (r/pacers 25, Broadway "MJ" 25), v_reddit_news_ticker 49.
-- Note: the cron.alter_job made pg_cron reload its job table; the scheduler
-- paused ~2.5 min (last run 18:34:47 → resumed 18:37) and then caught up.
--
-- WHY (KANBAN A1-OPS-SOCIAL-DEAD, operator call (b)): reddit_news is EMPTY.
--   1. reddit_news_queue_1min / _process_1min were paused by the 2026-08-31
--      pause-all-crons directive and never resumed (last flair poll 08-31).
--   2. Resuming alone would not work: old.reddit.com now answers our egress
--      with 404 "Not Found" for every search.rss URL (probed 2026-10-06:
--      r/nba flair:"News" → 404; broadway_social_poll's site-wide search → 404
--      ×60 in 6 h). The same URLs on www.reddit.com return 200 with the same
--      Atom <entry> feed reddit_news_process already parses (r/nba → 25
--      entries). JSON endpoints are 403 — RSS only.
--   3. broadway_social_poll kept firing every 2 min into reddit_news_pending
--      with nobody draining it: 2,270 unresolved rows, all 404s.
--
-- CHANGE
--   * Both URL builders: old.reddit.com → www.reddit.com (no other change).
--   * Resume crons 449 (queue, 1 subreddit/min) + 446 (process). Combined with
--     broadway's 1 request / 2 min that is ~1.5 req/min to Reddit — under the
--     unauthenticated RSS limit (a burst of 6 probes in 2 min drew one 429).
--   * Close pending rows whose HTTP response pg_net has already pruned
--     (> 6 h old): reddit_news_process joins on net._http_response, so those
--     can never resolve and would sit there forever.
--
-- rollback: SELECT cron.alter_job(<446|449>, active := false); restore the
-- old.reddit.com bodies from 20260714210000 / 20260714250000.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reddit_news_queue(p_limit int DEFAULT 1)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0; v_url text;
BEGIN
  FOR r IN
    SELECT f.subreddit, f.league, f.flair_query, f.search_query
    FROM reddit_news_flairs f
    WHERE f.enabled
      AND (f.last_polled_at IS NULL OR f.last_polled_at < now() - interval '4 minutes')
    ORDER BY f.last_polled_at ASC NULLS FIRST, f.subreddit
    LIMIT p_limit
  LOOP
    IF r.search_query IS NOT NULL AND btrim(r.search_query) <> '' THEN
      -- keyword search (trade/rumor subs with no News flair)
      v_url := 'https://www.reddit.com/r/' || r.subreddit || '/search.rss?q='
            || public.x_news_urlencode(r.search_query)
            || '&restrict_sr=on&sort=new&limit=25';
    ELSE
      -- flair:"News" (default path)
      v_url := 'https://www.reddit.com/r/' || r.subreddit
            || '/search.rss?q=flair%3A%22'
            || replace(r.flair_query, ' ', '%20')
            || '%22&restrict_sr=on&sort=new&limit=25';
    END IF;

    SELECT net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'User-Agent', 'Terminal2-S4K-RSS/1.0',
        'Accept', 'application/rss+xml, application/xml'),
      timeout_milliseconds := 12000
    ) INTO v_req_id;

    INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
    VALUES (r.subreddit, r.league, coalesce(r.search_query, r.flair_query), v_req_id, now());

    UPDATE reddit_news_flairs SET last_polled_at = now() WHERE subreddit = r.subreddit;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END; $$;

CREATE OR REPLACE FUNCTION public.broadway_social_poll(p_limit int DEFAULT 1)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s RECORD; v_req bigint; v_slug text; v_n int := 0;
BEGIN
  FOR s IN
    SELECT show_slug, title FROM broadway_show_ref
    WHERE watch AND coalesce(title,'') <> ''
      AND (social_last_polled_at IS NULL OR social_last_polled_at < now() - interval '15 minutes')
    ORDER BY social_last_polled_at ASC NULLS FIRST, show_slug
    LIMIT greatest(1, coalesce(p_limit, 1))
  LOOP
    v_slug := 'bway:'||left(s.show_slug, 18);
    SELECT net.http_get(
      url := 'https://www.reddit.com/search.rss?q='
             || x_news_urlencode('"'||s.title||'" Broadway') || '&sort=new&limit=25',
      headers := jsonb_build_object('User-Agent','Terminal2-S4K-RSS/1.0',
                                    'Accept','application/rss+xml, application/xml'),
      timeout_milliseconds := 12000
    ) INTO v_req;
    INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
    VALUES (v_slug, 'Broadway', s.title||' (broadway search)', v_req, now());
    UPDATE broadway_show_ref SET social_last_polled_at = now() WHERE show_slug = s.show_slug;
    v_n := v_n + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_n;
END $$;

-- Orphans: responses pruned by pg_net (> 6 h) can never be joined again.
UPDATE public.reddit_news_pending p
   SET resolved_at = now(), rows_persisted = 0
 WHERE p.resolved_at IS NULL
   AND p.fired_at < now() - interval '6 hours'
   AND NOT EXISTS (SELECT 1 FROM net._http_response h WHERE h.id = p.request_id);

-- Resume the wire (paused 2026-08-31, never resumed).
SELECT cron.alter_job(jobid, active := true)
  FROM cron.job
 WHERE jobname IN ('reddit_news_queue_1min', 'reddit_news_process_1min');
