-- ============================================================================
-- Migration 20260714150000 — Dedicated max-frequency LeBron poll (stopgap)
--
-- Lane:     A1 data plane (dedicated poller feeding the existing wire tables)
-- Touches:  lebron_poll (W: new fn), reddit_news_pending + x_news_pending (W:
--           enqueue), x_news_sources (W: disable the shared LeBron row — the
--           dedicated poll owns LeBron X now), 1 cron job. Reuses the existing
--           reddit_news_process / x_news_process drains (already 1-min crons).
-- Pre-reqs: 20260626120030 (reddit_news + reddit_news_process),
--           20260706114500 (x_news + x_news_process + x_news_urlencode),
--           20260706113000 (get_app_secret whitelists TWITTERAPI_IO_KEY)
--
-- WHY: operator wants LeBron's subs/sources polled at MAX frequency, LeBron-only
--   (a general player watchlist comes later). The X + Reddit news wires are
--   SHARED round-robin pollers (one source per tick across ~40+ sources), so no
--   per-source interval gives one player max cadence — he waits his turn. This
--   adds a DEDICATED LeBron poll that bypasses the round-robin: a site-wide
--   Reddit "LeBron James" search (free) + an X "LeBron James" advanced search
--   (paid; no-ops without the vault key / credits), fired every 3 min into the
--   existing *_pending queues and drained by the existing *_process fns. The
--   player page already reads these via get_player_social (name filter).
--
--   This is a LeBron-scoped stopgap — when the player watchlist ships, this
--   generalizes to a per-watchlisted-athlete poll and this one-off is retired.
--
-- Read-only upstream (RULE 2): GET-only via pg_net (old.reddit RSS + TwitterAPI.io
--   advanced_search) — same hosts/patterns the shared wires already use.
-- ============================================================================

-- The shared x_news_sources LeBron row would double-fire once the dedicated poll
-- owns LeBron X — disable it (the dedicated poll polls LeBron X far more often).
UPDATE x_news_sources SET enabled = false, updated_at = now()
 WHERE source_value ILIKE '%lebron%';

CREATE OR REPLACE FUNCTION public.lebron_poll()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_req bigint;
  v_key text;
  v_n   int := 0;
BEGIN
  -- (1) Reddit — site-wide "LeBron James" search, newest first (free RSS path).
  --     Stored under subreddit='lebron' (attribution label); reddit_news_process
  --     drains it. tweet/post-id PK dedupes overlap with the shared subs.
  SELECT net.http_get(
    url := 'https://old.reddit.com/search.rss?q=%22LeBron%20James%22&sort=new&limit=25',
    headers := jsonb_build_object(
      'User-Agent', 'Terminal2-S4K-RSS/1.0',
      'Accept', 'application/rss+xml, application/xml'),
    timeout_milliseconds := 12000
  ) INTO v_req;
  INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
  VALUES ('lebron', 'NBA', 'LeBron James (dedicated search)', v_req, now());
  v_n := v_n + 1;

  -- (2) X — "LeBron James" advanced search (paid). No-ops without the vault key
  --     (or while TwitterAPI.io credits are exhausted → the request just errors
  --     and x_news_process records it). Drained by x_news_process.
  BEGIN v_key := get_app_secret('TWITTERAPI_IO_KEY'); EXCEPTION WHEN OTHERS THEN v_key := NULL; END;
  IF v_key IS NOT NULL AND btrim(v_key) <> '' THEN
    SELECT net.http_get(
      url := 'https://api.twitterapi.io/twitter/tweet/advanced_search'
             || '?queryType=Latest&query='
             || x_news_urlencode('"LeBron James" -filter:retweets -filter:replies'),
      headers := jsonb_build_object('X-API-Key', v_key, 'Accept', 'application/json'),
      timeout_milliseconds := 15000
    ) INTO v_req;
    INSERT INTO x_news_pending(source_value, kind, league, request_id, fired_at)
    VALUES ('"LeBron James" (dedicated search)', 'query', 'NBA', v_req, now());
    v_n := v_n + 1;
  END IF;

  RETURN v_n;
END $$;

COMMENT ON FUNCTION public.lebron_poll() IS
  'Dedicated max-frequency LeBron poll (stopgap before the player watchlist): '
  'site-wide Reddit "LeBron James" search + X advanced search, fired into '
  'reddit_news_pending / x_news_pending and drained by the existing *_process '
  'crons. Read via get_player_social (name filter). Mig 20260714150000.';

-- Cron: every 3 min (minute marks 3,6,9,… avoid the saturated :00/:02/:05/:07
-- clusters). Reddit = one request/3min (well within old.reddit limits); X gated
-- on key/credits. The *_process fns (1-min crons) drain within a minute.
SELECT cron.schedule('lebron_poll_3min', '3-59/3 * * * *', $$ SELECT public.lebron_poll(); $$);

-- Kick off the first poll on apply.
SELECT public.lebron_poll();
