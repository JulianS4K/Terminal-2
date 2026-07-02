-- ============================================================================
-- Migration 20260702210000 — NEWS WIRE: source Reddit from the news pipeline
--
-- Lane:     D0 (author) → A1 (apply)   [D0 has no prod-DB apply authority]
-- Touches:  get_terminal_news_ticker (W, CREATE OR REPLACE)
--           espn_news (R), espn_teams_canonical (R), v_reddit_news_ticker (R)
-- Pre-reqs: 20260629120000 (get_terminal_news_ticker v1)
--           20260626120030 (v_reddit_news_ticker — the flair-filtered news view)
--
-- WHY: the D0 NEWS WIRE RPC (mig 20260629120000) unioned Reddit from
--   v_reddit_important_recent — the DORMANT keyword-sentiment pipeline (reddit_*
--   crons paused 20260513002000), so the Reddit source contributed 0 rows. The
--   new flair-filtered NEWS pipeline (mig 20260626120030, v_reddit_news_ticker)
--   is the intended source: title-only, News-flair posts, 48h retention, deduped
--   first-post-shows, with the source subreddit exposed. This repoints the RPC's
--   reddit CTE at that view. No signature/shape change — the FE (news-ticker.js)
--   is unchanged except for showing the sub.
--
-- CHANGES vs v1 reddit CTE:
--   * FROM v_reddit_important_recent  →  FROM v_reddit_news_ticker
--   * league taken from the view's denormalized column (no gs/ps joins needed)
--   * team = 'r/' || subreddit  →  carries the source sub for UI attribution
--     (the RPC already returns `team`; the FE renders it next to Reddit rows)
--   * url = coalesce(external link, reddit permalink) → clicks go to the article
--     when there is one, else the reddit thread
--   * item_type 'reddit' → 'reddit_news'
--   * CROSS-SOURCE dedup: a Reddit row whose external link matches an ESPN
--     article's URL (normalized) is dropped — ESPN wins. So the same story
--     posted to Reddit and covered by ESPN shows once (the ESPN row).
--
-- Read-only by construction: pure SELECT over RLS-locked read surfaces. REVOKE
--   PUBLIC + GRANT to the same read roles as v1.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_terminal_news_ticker(
  p_window_hours integer DEFAULT 48,
  p_sources      text[]  DEFAULT NULL,
  p_leagues      text[]  DEFAULT NULL,
  p_search       text    DEFAULT NULL,
  p_limit        integer DEFAULT 100
)
RETURNS TABLE(
  source       text,
  league       text,
  team         text,
  headline     text,
  summary      text,
  url          text,
  image_url    text,
  item_type    text,
  published_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH params AS (
    SELECT
      GREATEST(1, LEAST(coalesce(p_window_hours, 48), 720)) AS win_hours,
      GREATEST(1, LEAST(coalesce(p_limit, 100), 300))       AS lim,
      NULLIF(btrim(coalesce(p_search, '')), '')             AS q
  ),
  espn AS (
    SELECT
      'ESPN'::text                             AS source,
      e.espn_league                            AS league,
      coalesce(t.display_name, t.abbreviation) AS team,
      e.headline                               AS headline,
      e.description                            AS summary,
      e.url                                    AS url,
      e.image_url                              AS image_url,
      e.type                                   AS item_type,
      e.published_at                           AS published_at
    FROM public.espn_news e
    LEFT JOIN public.espn_teams_canonical t
      ON t.espn_team_id = e.espn_team_id
     AND t.espn_league  = e.espn_league
    WHERE e.published_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'ESPN' = ANY (p_sources))
  ),
  reddit AS (
    SELECT
      'Reddit'::text                                   AS source,
      r.league                                         AS league,
      'r/' || r.subreddit                              AS team,
      r.title                                          AS headline,
      NULL::text                                       AS summary,
      coalesce(NULLIF(r.link_url, ''), r.permalink)    AS url,
      NULL::text                                       AS image_url,
      'reddit_news'::text                              AS item_type,
      r.created_utc                                    AS published_at
    FROM public.v_reddit_news_ticker r
    WHERE r.created_utc > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Reddit' = ANY (p_sources))
      -- Cross-source dedup: drop a Reddit row whose EXTERNAL article link points
      -- at the same story ESPN already carries (ESPN is the authoritative
      -- source, so it wins). Match on a normalized URL (strip scheme / www /
      -- query / fragment / trailing slash). Reddit rows with no external link
      -- (link_url NULL → url is the reddit permalink) can never collide, so they
      -- are kept. Scoped to the same window as the espn CTE.
      AND (
        r.link_url IS NULL OR r.link_url = '' OR NOT EXISTS (
          SELECT 1 FROM public.espn_news e
          WHERE e.url IS NOT NULL
            AND e.published_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
            AND rtrim(lower(regexp_replace(regexp_replace(e.url,    '[#?].*$', ''), '^https?://(www\.)?', '')), '/')
              = rtrim(lower(regexp_replace(regexp_replace(r.link_url,'[#?].*$', ''), '^https?://(www\.)?', '')), '/')
        )
      )
  ),
  unioned AS (
    SELECT * FROM espn
    UNION ALL
    SELECT * FROM reddit
  )
  SELECT u.source, u.league, u.team, u.headline, u.summary, u.url,
         u.image_url, u.item_type, u.published_at
  FROM unioned u, params
  WHERE (p_leagues IS NULL OR u.league = ANY (p_leagues))
    AND (params.q IS NULL
         OR u.headline ILIKE '%' || params.q || '%'
         OR coalesce(u.summary, '') ILIKE '%' || params.q || '%'
         OR coalesce(u.team, '')    ILIKE '%' || params.q || '%')
  ORDER BY u.published_at DESC NULLS LAST
  LIMIT (SELECT lim FROM params);
$function$;

REVOKE ALL ON FUNCTION public.get_terminal_news_ticker(integer, text[], text[], text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_terminal_news_ticker(integer, text[], text[], text, integer)
  TO anon, authenticated, coworker_readonly;

COMMENT ON FUNCTION public.get_terminal_news_ticker(integer, text[], text[], text, integer) IS
  'D0 terminal NEWS WIRE feed. Unified, filterable, newest-first headlines from '
  'espn_news (live) + v_reddit_news_ticker (flair:"News" pipeline, 48h, deduped '
  'first-post-shows; team = ''r/<sub>'' for source attribution). SECURITY DEFINER '
  'read surface for the authenticated terminal client. Params: window hours, '
  'sources[], leagues[], search, limit.';
