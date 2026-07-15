-- ============================================================================
-- Migration 20260714250000 — Broadway watchlist + per-show social poll
--
-- Lane:     A1 data plane (broadway surface — cast/social tracking)
-- Touches:  broadway_show_ref (W: +watch, +social_last_polled_at),
--           broadway_social_poll (W: new), reddit_news_pending (W: enqueue),
--           1 cron
-- Pre-reqs: 20260703013000 (broadway cast pipeline), 20260626120030 (reddit_news),
--           20260706114500 (x_news_urlencode)
--
-- WHY: operator — "apply the performers you mentioned to the watchlist." The hot
--   cast-change shows (Death of a Salesman, MJ, Book of Mormon, Lost Boys, …) are
--   the Broadway analog of the watchlisted players. They're already wiki-watched
--   (broadway_cast_pull_log) and on Cast Watch; this adds the missing piece — a
--   dedicated per-show SOCIAL poll (a site-wide Reddit search on the show title +
--   "Broadway" to cut non-theatre noise), round-robin, feeding reddit_news (the
--   wire + any future get_cast_feed). watch=true marks the tracked subset.
--
-- Read-only upstream (RULE 2): GET-only old.reddit RSS, same as the base pipeline.
-- ============================================================================

ALTER TABLE broadway_show_ref
  ADD COLUMN IF NOT EXISTS watch                boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS social_last_polled_at timestamptz;

COMMENT ON COLUMN broadway_show_ref.watch IS
  'On the Broadway watchlist → broadway_social_poll polls this show''s Reddit '
  'chatter. Mig 20260714250000.';

-- Seed: the hot cast-change shows flagged earlier.
UPDATE broadway_show_ref SET watch = true
 WHERE show_slug IN ('death-of-a-salesman','mj','book-of-mormon','lost-boys',
                     'stranger-things','cursed-child','the-outsiders','oh-mary');

-- ----------------------------------------------------------------------------
-- Per-show social poll — round-robin over watched shows (least-recently-polled),
-- ~15-min floor per show. Site-wide Reddit search on the title + "Broadway".
-- ----------------------------------------------------------------------------
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
      url := 'https://old.reddit.com/search.rss?q='
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

COMMENT ON FUNCTION public.broadway_social_poll(int) IS
  'Round-robin Reddit search over watched Broadway shows (title + "Broadway"), '
  'drained by reddit_news_process. Broadway twin of watchlist_social_poll. '
  'Mig 20260714250000.';

-- Cron: every 2 min, one show/tick (8 shows → each ~every 16 min). Odd minutes
-- avoid the saturated :00/:02/:05/:07 clusters.
SELECT cron.schedule('broadway_social_poll_2min', '1-59/2 * * * *',
  $$ SELECT public.broadway_social_poll(1); $$);
SELECT public.broadway_social_poll(1);
