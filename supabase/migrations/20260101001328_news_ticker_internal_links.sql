-- Point the terminal NEWS WIRE items at our own entity pages instead of ESPN.
--
-- Now that transactions/scores/standings map to a TEvo performer (via
-- performer_espn_team_xref) and injuries carry an espn_athletes id, each news
-- item can deep-link INTERNALLY:
--   * transactions -> performer.html?performer=<tevo_performer_id>   (the team)
--   * scores       -> performer.html?performer=<home team performer>
--   * standings    -> performer.html?performer=<team performer>
--   * injuries     -> player.html?player=<athlete_id>&league=<league>
-- Each falls back to the external ESPN page when unmapped. ESPN news + Reddit
-- rows keep their article URLs (nothing internal to point at). The relative
-- hrefs resolve under /terminal/ exactly like the nav links; news-ticker.js
-- renders a relative url as a same-tab internal link, an http(s) url as an
-- external one.
--
-- Only the url expressions change (+ scalar performer lookups that can't
-- fan-out the row set); every other column and the RETURNS TABLE are identical.

CREATE OR REPLACE FUNCTION public.get_terminal_news_ticker(
  p_window_hours integer DEFAULT 48,
  p_sources text[] DEFAULT NULL::text[],
  p_leagues text[] DEFAULT NULL::text[],
  p_search text DEFAULT NULL::text,
  p_limit integer DEFAULT 100)
 RETURNS TABLE(source text, league text, team text, headline text, summary text, url text, image_url text, item_type text, published_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
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
  transactions AS (
    SELECT
      'Transactions'::text                                     AS source,
      tx.espn_league                                           AS league,
      coalesce(c.display_name, c.abbreviation, tx.team_display_name, tx.team_abbr) AS team,
      coalesce(tx.team_display_name || ': ', '') || tx.description                  AS headline,
      NULL::text                                               AS summary,
      coalesce(
        'performer.html?performer=' || (
          SELECT x.tevo_performer_id FROM public.performer_espn_team_xref x
          WHERE x.espn_team_id = tx.espn_team_id AND x.espn_league = tx.espn_league LIMIT 1)::text,
        CASE lower(tx.espn_league)
          WHEN 'nfl'  THEN 'https://www.espn.com/nfl/transactions'
          WHEN 'nba'  THEN 'https://www.espn.com/nba/transactions'
          WHEN 'wnba' THEN 'https://www.espn.com/wnba/transactions'
          WHEN 'mlb'  THEN 'https://www.espn.com/mlb/transactions'
          WHEN 'nhl'  THEN 'https://www.espn.com/nhl/transactions'
          ELSE NULL END)                                       AS url,
      NULL::text                                               AS image_url,
      'transaction'::text                                      AS item_type,
      tx.txn_date                                              AS published_at
    FROM public.espn_transactions tx
    LEFT JOIN public.espn_teams_canonical c
      ON c.espn_team_id = tx.espn_team_id AND c.espn_league = tx.espn_league
    WHERE tx.txn_date > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND coalesce(tx.description, '') <> ''
      AND (p_sources IS NULL OR 'Transactions' = ANY (p_sources))
  ),
  injuries AS (
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
      coalesce(
        'player.html?player=' || max(i.athlete_id) || '&league=' || max(i.espn_league),
        CASE lower(max(i.espn_league))
          WHEN 'nfl'  THEN 'https://www.espn.com/nfl/injuries'
          WHEN 'nba'  THEN 'https://www.espn.com/nba/injuries'
          WHEN 'wnba' THEN 'https://www.espn.com/wnba/injuries'
          WHEN 'mlb'  THEN 'https://www.espn.com/mlb/injuries'
          WHEN 'nhl'  THEN 'https://www.espn.com/nhl/injuries'
          ELSE NULL END)                            AS url,
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
    SELECT DISTINCT ON (s.espn_event_id, s.espn_league)
      'Scores'::text                             AS source,
      s.espn_league                              AS league,
      coalesce(ha.display_name, ha.abbreviation) AS team,
      coalesce(aw.display_name, aw.abbreviation, 'Away') || ' ' || coalesce(s.away_score::text, '0')
        || ', ' || coalesce(ha.display_name, ha.abbreviation, 'Home') || ' ' || coalesce(s.home_score::text, '0')
        || coalesce(' · ' || NULLIF(s.status_short, ''), '') AS headline,
      NULL::text                                 AS summary,
      coalesce(
        'performer.html?performer=' || (
          SELECT x.tevo_performer_id FROM public.performer_espn_team_xref x
          WHERE x.espn_team_id = s.home_team_id AND x.espn_league = s.espn_league LIMIT 1)::text,
        CASE lower(s.espn_league)
          WHEN 'nfl'  THEN 'https://www.espn.com/nfl/scoreboard'
          WHEN 'nba'  THEN 'https://www.espn.com/nba/scoreboard'
          WHEN 'wnba' THEN 'https://www.espn.com/wnba/scoreboard'
          WHEN 'mlb'  THEN 'https://www.espn.com/mlb/scoreboard'
          WHEN 'nhl'  THEN 'https://www.espn.com/nhl/scoreboard'
          ELSE NULL END)                         AS url,
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
    SELECT DISTINCT ON (t.espn_team_id, t.espn_league)
      'Standings'::text                        AS source,
      t.espn_league                            AS league,
      coalesce(c.display_name, c.abbreviation) AS team,
      coalesce(c.display_name, c.abbreviation) || ' ' || coalesce(t.record_summary, '')
        || coalesce(' · ' || NULLIF(t.streak, ''), '')
        || coalesce(' · #' || t.playoff_seed || ' seed', '') AS headline,
      NULL::text                               AS summary,
      coalesce(
        'performer.html?performer=' || (
          SELECT x.tevo_performer_id FROM public.performer_espn_team_xref x
          WHERE x.espn_team_id = t.espn_team_id AND x.espn_league = t.espn_league LIMIT 1)::text,
        CASE lower(t.espn_league)
          WHEN 'nfl'  THEN 'https://www.espn.com/nfl/standings'
          WHEN 'nba'  THEN 'https://www.espn.com/nba/standings'
          WHEN 'wnba' THEN 'https://www.espn.com/wnba/standings'
          WHEN 'mlb'  THEN 'https://www.espn.com/mlb/standings'
          WHEN 'nhl'  THEN 'https://www.espn.com/nhl/standings'
          ELSE NULL END)                       AS url,
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
    UNION ALL SELECT * FROM transactions
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
