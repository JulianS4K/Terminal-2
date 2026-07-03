-- ============================================================================
-- Migration 20260702231500 — NEWS WIRE: scores = FINAL only (live stays on event page)
--
-- Lane:     D0 (author + apply — A1 lane retired 2026-07-02, applies are now
--           operator/session-run)
-- Touches:  get_terminal_news_ticker (W, CREATE OR REPLACE)
--           espn_news (R), espn_teams_canonical (R), espn_injuries_snapshots (R),
--           espn_event_snapshots (R)  ← NEW, espn_team_snapshots (R)  ← NEW,
--           v_reddit_news_ticker (R)
-- Pre-reqs: 20260702230040 (get_terminal_news_ticker + injuries CTE)
--           20260507000013 (espn_event_snapshots, espn_team_snapshots)
--           20260507000017 (change-only ingest — event/team snapshots keyed on
--                           stable ids, so NO provisional-id churn like injuries)
--
-- WHY: operator directive 2026-07-02 — surface ESPN game scores and league
--   standings in the D0 NEWS WIRE alongside news + injuries + reddit. Both feeds
--   are fed live by espn-collect (gameday scope every 10 min → scores; team_daily
--   05:00 → standings) via the change-only upsert RPCs. Like the other ESPN
--   tables their RLS is deny-all for authenticated/anon, so this SECURITY DEFINER
--   ticker RPC is the terminal's read path.
--
-- CHANGE vs 20260702231000: the `scores` CTE now shows FINAL games only
--   (state = 'post', was state IN ('in','post')). Operator directive 2026-07-02:
--   the NEWS WIRE should carry settled results, not in-progress scores — LIVE
--   scores stay on the event page (which reads espn_event_snapshots via its own
--   RPCs, unaffected by this ticker change). Everything else below is unchanged
--   from 20260702231000 (re-stated in full for a self-contained CREATE OR REPLACE).
--
-- Full source list (unchanged):
--   * `scores` CTE over espn_event_snapshots — one row per game (DISTINCT ON
--     event, latest snapshot), FINAL only (state = 'post'). espn_event_id is
--     STABLE so a plain latest-per-event is correct. published_at = captured_at.
--       - source='Scores', item_type='score'
--       - headline = "<away> <a>, <home> <h> · <status_short>"  e.g.
--         "Detroit Tigers 9, New York Yankees 3 · Final"
--       - url = ESPN league scoreboard (majors) else NULL
--   * NEW `standings` CTE over espn_team_snapshots — one row per team (DISTINCT
--     ON team, latest snapshot). Stable team-id key, no churn.
--       - source='Standings', item_type='standing'
--       - headline = "<team> <record> · <streak> · #<seed> seed"  e.g.
--         "Milwaukee Brewers 53-31 · W3 · #2 seed"
--       - url = ESPN league standings page (majors) else NULL
--   * unioned now = espn ∪ injuries ∪ scores ∪ standings ∪ reddit; the outer
--     recency ORDER BY + LIMIT and the p_sources/p_leagues/search filters apply
--     uniformly, so the FE gains 'Scores'/'Standings' source values (also under
--     "All"). No signature/shape change — RETURNS TABLE columns are identical.
--   * team_id is reused across leagues (RESOURCES_BIBLE ESPN RULE 1) → every
--     espn_teams_canonical join is ON (espn_team_id AND espn_league).
--
-- Read-only by construction: pure SELECT over RLS-locked read surfaces. REVOKE
--   PUBLIC + GRANT to the same read roles as before.
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
  injuries AS (
    -- Grouped by content w/ first-seen time to collapse ESPN's per-poll
    -- provisional-athlete-id churn (mig 20260520220000 / 20260702230040).
    SELECT
      'Injuries'::text                              AS source,
      max(i.espn_league)                            AS league,
      max(coalesce(t.display_name, t.abbreviation)) AS team,
      max(i.athlete_name)
        || coalesce(' (' || NULLIF(max(i.position), '') || ')', '')
        || coalesce(' — ' || NULLIF(max(i.status), ''), '')
        || CASE WHEN NULLIF(max(i.injury_type), '') IS NOT NULL
                     AND lower(max(i.injury_type)) <> lower(coalesce(max(i.status), ''))
                THEN ' · ' || max(i.injury_type) ELSE '' END   AS headline,
      NULLIF(
        coalesce(NULLIF(max(i.short_comment), ''), NULLIF(max(i.long_comment), ''), '')
        || CASE WHEN max(i.return_date) IS NOT NULL
                THEN ' (est. return ' || to_char(max(i.return_date), 'Mon DD') || ')'
                ELSE '' END,
        '')                                         AS summary,
      CASE lower(max(i.espn_league))
        WHEN 'nfl'  THEN 'https://www.espn.com/nfl/injuries'
        WHEN 'nba'  THEN 'https://www.espn.com/nba/injuries'
        WHEN 'wnba' THEN 'https://www.espn.com/wnba/injuries'
        WHEN 'mlb'  THEN 'https://www.espn.com/mlb/injuries'
        WHEN 'nhl'  THEN 'https://www.espn.com/nhl/injuries'
        ELSE NULL
      END                                           AS url,
      NULL::text                                    AS image_url,
      'injury'::text                                AS item_type,
      min(i.captured_at)                            AS published_at
    FROM public.espn_injuries_snapshots i
    LEFT JOIN public.espn_teams_canonical t
      ON t.espn_team_id = i.espn_team_id
     AND t.espn_league  = i.espn_league
    WHERE coalesce(i.athlete_name, '') <> ''
      AND (p_sources IS NULL OR 'Injuries' = ANY (p_sources))
      AND i.captured_at > now() - (((SELECT win_hours FROM params) + 24) || ' hours')::interval
    GROUP BY i.espn_team_id, i.espn_league,
             lower(i.athlete_name), lower(coalesce(i.status, '')), lower(coalesce(i.injury_type, ''))
    HAVING min(i.captured_at) > now() - ((SELECT win_hours FROM params) || ' hours')::interval
  ),
  scores AS (
    -- Latest snapshot per game, FINAL only (state='post'; live scores stay on the
    -- event page). espn_event_id is stable → plain latest-per-event (no churn
    -- grouping needed, unlike injuries).
    SELECT DISTINCT ON (s.espn_event_id, s.espn_league)
      'Scores'::text                             AS source,
      s.espn_league                              AS league,
      coalesce(ha.display_name, ha.abbreviation) AS team,
      coalesce(aw.display_name, aw.abbreviation, 'Away') || ' ' || coalesce(s.away_score::text, '0')
        || ', ' || coalesce(ha.display_name, ha.abbreviation, 'Home') || ' ' || coalesce(s.home_score::text, '0')
        || coalesce(' · ' || NULLIF(s.status_short, ''), '') AS headline,
      NULL::text                                 AS summary,
      CASE lower(s.espn_league)
        WHEN 'nfl'  THEN 'https://www.espn.com/nfl/scoreboard'
        WHEN 'nba'  THEN 'https://www.espn.com/nba/scoreboard'
        WHEN 'wnba' THEN 'https://www.espn.com/wnba/scoreboard'
        WHEN 'mlb'  THEN 'https://www.espn.com/mlb/scoreboard'
        WHEN 'nhl'  THEN 'https://www.espn.com/nhl/scoreboard'
        ELSE NULL
      END                                        AS url,
      NULL::text                                 AS image_url,
      'score'::text                              AS item_type,
      s.captured_at                              AS published_at
    FROM public.espn_event_snapshots s
    LEFT JOIN public.espn_teams_canonical ha
      ON ha.espn_team_id = s.home_team_id AND ha.espn_league = s.espn_league
    LEFT JOIN public.espn_teams_canonical aw
      ON aw.espn_team_id = s.away_team_id AND aw.espn_league = s.espn_league
    WHERE s.state = 'post'
      AND s.captured_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Scores' = ANY (p_sources))
    ORDER BY s.espn_event_id, s.espn_league, s.captured_at DESC
  ),
  standings AS (
    -- Latest standings snapshot per team. Stable team-id key, no churn.
    SELECT DISTINCT ON (t.espn_team_id, t.espn_league)
      'Standings'::text                        AS source,
      t.espn_league                            AS league,
      coalesce(c.display_name, c.abbreviation) AS team,
      coalesce(c.display_name, c.abbreviation) || ' ' || coalesce(t.record_summary, '')
        || coalesce(' · ' || NULLIF(t.streak, ''), '')
        || coalesce(' · #' || t.playoff_seed || ' seed', '') AS headline,
      NULL::text                               AS summary,
      CASE lower(t.espn_league)
        WHEN 'nfl'  THEN 'https://www.espn.com/nfl/standings'
        WHEN 'nba'  THEN 'https://www.espn.com/nba/standings'
        WHEN 'wnba' THEN 'https://www.espn.com/wnba/standings'
        WHEN 'mlb'  THEN 'https://www.espn.com/mlb/standings'
        WHEN 'nhl'  THEN 'https://www.espn.com/nhl/standings'
        ELSE NULL
      END                                      AS url,
      NULL::text                               AS image_url,
      'standing'::text                         AS item_type,
      t.captured_at                            AS published_at
    FROM public.espn_team_snapshots t
    LEFT JOIN public.espn_teams_canonical c
      ON c.espn_team_id = t.espn_team_id AND c.espn_league = t.espn_league
    WHERE t.captured_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND coalesce(t.record_summary, '') <> ''
      AND (p_sources IS NULL OR 'Standings' = ANY (p_sources))
    ORDER BY t.espn_team_id, t.espn_league, t.captured_at DESC
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
    UNION ALL SELECT * FROM injuries
    UNION ALL SELECT * FROM scores
    UNION ALL SELECT * FROM standings
    UNION ALL SELECT * FROM reddit
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
  'D0 terminal NEWS WIRE feed. Unified, filterable, newest-first items from '
  'espn_news (news) + espn_injuries_snapshots (Injuries) + espn_event_snapshots '
  '(Scores: FINAL only, latest per game) + espn_team_snapshots (Standings: latest '
  'per team) + v_reddit_news_ticker (Reddit). SECURITY DEFINER read surface. '
  'Params: window hours, sources[] (ESPN|Injuries|Scores|Standings|Reddit), '
  'leagues[], search, limit.';
