-- ============================================================================
-- Migration 20260629120000 — D0 terminal: NEWS WIRE ticker RPC
--
-- Lane:     D0 (author) → A1 (apply)   [D0 has no prod-DB apply authority]
-- Touches:  get_terminal_news_ticker (W, CREATE OR REPLACE — new fn)
--           espn_news (R), espn_teams_canonical (R),
--           v_reddit_important_recent (R), general_subreddits (R),
--           performer_subreddits (R)
-- Pre-reqs: 20260507000013_event_xref_and_espn_snapshots.sql (espn_news)
--           20260509410000_betting_odds_and_reddit_signals.sql (performer_subreddits)
--           20260509420000_x_accounts_keywords_full_subreddits.sql
--             (v_reddit_important_recent, general_subreddits)
--           espn_teams_canonical (team display names)
--
-- WHY: the D0 terminal home page had no news surface. espn_news is fed live by
--   the espn-collect crons (~80 articles/24h across 7 leagues: MLB / World Cup /
--   NFL / WNBA / NBA / NHL / MLS) but the authenticated terminal client cannot
--   read it directly — espn_news RLS is admin_only (USING(false) for
--   authenticated/anon/coworker_readonly). This SECURITY DEFINER table-function
--   is the read surface the terminal calls (same pattern as get_event_movers_v2)
--   — a single, filterable, newest-first news feed.
--
--   Sources unified:
--     * ESPN   — espn_news (LIVE). Team display name via espn_teams_canonical.
--     * Reddit — v_reddit_important_recent (keyword-filtered). DORMANT: the
--                reddit_* crons were paused (mig 20260513002000, resource
--                pressure) so this contributes 0 rows today; the UNION lights up
--                automatically if/when A1 re-enables the pull. League resolved
--                via general_subreddits / performer_subreddits.
--
--   Filters (all optional): window hours, sources[], leagues[], free-text search.
--
-- Read-only by construction: pure SELECT over RLS-locked read tables, no writes,
--   no upstream-API calls (RULE 2 N/A). REVOKE PUBLIC + GRANT to the same read
--   roles the underlying tables carry (anon / authenticated / coworker_readonly).
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
      'Reddit'::text                 AS source,
      coalesce(gs.league, ps.league) AS league,
      NULL::text                     AS team,
      r.title                        AS headline,
      NULL::text                     AS summary,
      r.url                          AS url,
      NULL::text                     AS image_url,
      'reddit'::text                 AS item_type,
      r.created_utc                  AS published_at
    FROM public.v_reddit_important_recent r
    LEFT JOIN public.general_subreddits  gs ON lower(gs.subreddit) = lower(r.subreddit)
    LEFT JOIN public.performer_subreddits ps ON lower(ps.subreddit) = lower(r.subreddit)
    WHERE r.created_utc > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Reddit' = ANY (p_sources))
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
  'D0 terminal NEWS WIRE feed. Unified, filterable, newest-first headlines from espn_news (live) + v_reddit_important_recent (dormant until reddit crons re-enabled). SECURITY DEFINER read surface for the authenticated terminal client (espn_news/event_metrics RLS is admin_only). Params: window hours, sources[], leagues[], search, limit.';
