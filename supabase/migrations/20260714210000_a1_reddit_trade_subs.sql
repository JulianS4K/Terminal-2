-- ============================================================================
-- Migration 20260714210000 — Reddit trade-news subs (keyword-search mode)
--
-- Lane:     A1 data plane
-- Touches:  reddit_news_flairs (W: +search_query column, + trade-sub rows),
--           reddit_news_queue (W: keyword-search branch)
-- Pre-reqs: 20260626120030 (reddit_news pipeline)
--
-- WHY: operator wants more subs tracking trade news. The dedicated NBA
--   trade/rumor subs (r/nbatrades, r/nbadiscussion, r/NBATalk, …) don't use a
--   "News" flair, so the flair:"News" search returns nothing (r/nbadiscussion was
--   explicitly excluded in mig 20260626120030 for exactly this). This adds an
--   optional per-sub `search_query`: when set, the queue searches that sub for
--   the keywords instead of the News flair — so trade/signing/rumor posts flow.
--   Feeds the global wire AND every watchlisted player's feed (name filter).
--
-- Read-only upstream (RULE 2): GET-only old.reddit RSS, same as the base pipeline.
-- ============================================================================

ALTER TABLE reddit_news_flairs ADD COLUMN IF NOT EXISTS search_query text;
COMMENT ON COLUMN reddit_news_flairs.search_query IS
  'Optional keyword query. When set, reddit_news_queue searches the sub for these '
  'terms (restrict_sr) instead of flair:"<flair_query>" — for trade/rumor subs '
  'that have no News flair. Mig 20260714210000.';

-- Queue: add a keyword-search branch (search_query) alongside the flair path.
CREATE OR REPLACE FUNCTION reddit_news_queue(p_limit int DEFAULT 1)
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
      v_url := 'https://old.reddit.com/r/' || r.subreddit || '/search.rss?q='
            || public.x_news_urlencode(r.search_query)
            || '&restrict_sr=on&sort=new&limit=25';
    ELSE
      -- flair:"News" (default path)
      v_url := 'https://old.reddit.com/r/' || r.subreddit
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

-- Trade / rumor / movement subs — keyword search (they have no News flair).
-- Terms cover the common trade-news vocabulary; sort=new keeps it fresh.
INSERT INTO reddit_news_flairs (subreddit, league, flair_query, search_query, enabled, notes)
VALUES
  -- r/nbatrades search RSS returns 403 (blocked to our datacenter IP) → disabled.
  ('nbatrades',     'NBA', 'News', 'trade OR sign OR waive OR rumor OR "free agent"', false,
   'NBA trade discussion — search RSS 403 (blocked); disabled. Mig 20260714210000.'),
  ('nbadiscussion', 'NBA', 'News', 'trade OR sign OR rumor OR "free agency" OR waive', true,
   'NBA analysis/discussion — keyword search. Mig 20260714210000.'),
  ('NBATalk',       'NBA', 'News', 'trade OR sign OR rumor OR "free agent"', true,
   'NBA general talk — keyword search. Mig 20260714210000.'),
  ('sportsbook',    'NBA', 'News', 'NBA trade OR NBA signing OR NBA "free agent"', true,
   'Betting movement incl. player transactions — NBA-narrowed keyword search. Mig 20260714210000.'),
  ('fantasybball',  'NBA', 'News', 'trade OR waive OR sign OR "waiver"', true,
   'Fantasy hoops — roster-move keyword search. Mig 20260714210000.')
ON CONFLICT (subreddit) DO UPDATE
  SET search_query = EXCLUDED.search_query, enabled = EXCLUDED.enabled,
      league = EXCLUDED.league, notes = EXCLUDED.notes, updated_at = now();
