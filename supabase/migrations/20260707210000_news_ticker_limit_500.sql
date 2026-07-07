-- ============================================================================
-- Migration 20260707210000 — news ticker: raise the fetch cap 300 → 500
--
-- Lane:     xref+macro (A1 data plane)
-- Touches:  get_terminal_news_ticker (W/function)
-- Pre-reqs: 20260707190000 (current ticker body — restated verbatim here,
--           live prod prosrc md5-verified == that file before this change)
--
-- Operator directive (2026-07-07): "add these feeds to all and extend all to
-- 500 from 300". With X live the wire now carries 10 sources; the 300-row
-- newest-first cap could crowd lower-cadence sources (Standings, Fed) and the
-- X backlog out of the FE's single fetch. Only the p_limit clamp in the params
-- CTE changes (300 → 500); every CTE below it is verbatim from 20260707190000.
-- Companion FE change bumps FETCH_LIMIT to 500 in static/terminal/news-ticker.js.
-- ============================================================================

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
      GREATEST(1, LEAST(coalesce(p_limit, 100), 500))       AS lim,
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
  bway_current AS (
    SELECT DISTINCT ON (cr.show_slug)
      cr.id AS cast_run_id, cr.show_slug, cr.role, cr.performer_name,
      cr.run_start, cr.last_seen_at
    FROM public.broadway_cast_run cr
    WHERE cr.run_start IS NOT NULL
    ORDER BY cr.show_slug,
      (cr.run_start <= current_date AND (cr.run_end IS NULL OR cr.run_end >= current_date)) DESC,
      cr.run_start DESC NULLS LAST
  ),
  broadway AS (
    SELECT 'Broadway'::text AS source, 'Broadway'::text AS league,
      r.title AS team,
      r.title || ' — ' || bc.performer_name
        || coalesce(' as ' || NULLIF(bc.role, ''), '') AS headline,
      NULLIF(
        coalesce('leading since ' || to_char(bc.run_start, 'Mon DD'), '')
        || coalesce(' · get-in avg $' || round(g.avg_getin)::text, '')
        || coalesce(' · closing $' || round(g.closing_night_getin)::text, ''), '') AS summary,
      'performer.html?performer=' || r.tevo_performer_id::text
        || coalesce('&venue=' || r.tevo_venue_id::text, '') AS url,
      NULL::text AS image_url, 'cast'::text AS item_type,
      coalesce(r.cast_last_polled_at, bc.last_seen_at, bc.run_start::timestamptz) AS published_at
    FROM bway_current bc
    JOIN public.broadway_show_ref r ON r.show_slug = bc.show_slug
    LEFT JOIN public.v_broadway_performer_getin g ON g.cast_run_id = bc.cast_run_id
    WHERE r.tevo_performer_id IS NOT NULL
      AND (p_sources IS NULL OR 'Broadway' = ANY (p_sources))
  ),
  bway_flags AS (
    SELECT 'Broadway'::text AS source, 'Broadway'::text AS league,
      r.title AS team,
      r.title || ' — cast update detected' AS headline,
      'Wikipedia cast section changed — possible lead change; review the cast timeline.'::text AS summary,
      'performer.html?performer=' || r.tevo_performer_id::text
        || coalesce('&venue=' || r.tevo_venue_id::text, '') AS url,
      NULL::text AS image_url, 'cast'::text AS item_type, pl.created_at AS published_at
    FROM public.broadway_cast_pull_log pl
    JOIN public.broadway_show_ref r ON r.show_slug = pl.show_slug
    WHERE (pl.section_changed OR pl.flag_raised)
      AND r.tevo_performer_id IS NOT NULL
      AND pl.created_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Broadway' = ANY (p_sources))
  ),
  -- Fed / FRED macro releases. One row per enabled FRED series for its latest
  -- reading, surfaced only while that reading is fresh — published_at = when the
  -- value first landed in our store (see mig 20260705120000). Between releases
  -- the row ages out of the window, so the wire flashes the Fed only when it
  -- actually updates.
  macro AS (
    WITH fred_series AS (
      SELECT series_id, display_name, units
      FROM public.macro_series_config
      WHERE enabled = true AND source = 'FRED'
    ),
    -- current vintage value per (series, observation_date): latest realtime_start wins
    vintage AS (
      SELECT DISTINCT ON (mi.series_id, mi.observation_date)
        mi.series_id, mi.observation_date, mi.value
      FROM public.macro_indicators mi
      JOIN fred_series fs ON fs.series_id = mi.series_id
      WHERE mi.value IS NOT NULL
      ORDER BY mi.series_id, mi.observation_date DESC, mi.realtime_start DESC
    ),
    seq AS (
      SELECT v.series_id, v.observation_date, v.value,
             row_number() OVER w AS rn,
             lead(v.value) OVER w AS prior_value
      FROM vintage v
      WINDOW w AS (PARTITION BY v.series_id ORDER BY v.observation_date DESC)
    ),
    latest AS (
      SELECT series_id, observation_date, value, prior_value
      FROM seq WHERE rn = 1
    ),
    -- min(ingested_at) over the current reading = when it first arrived ≈ release
    landed AS (
      SELECT l.series_id, l.observation_date, l.value, l.prior_value,
             min(mi.ingested_at) AS first_seen
      FROM latest l
      JOIN public.macro_indicators mi
        ON mi.series_id = l.series_id
       AND mi.observation_date = l.observation_date
       AND mi.value = l.value
      GROUP BY l.series_id, l.observation_date, l.value, l.prior_value
    )
    SELECT
      'Fed'::text   AS source,
      'MACRO'::text AS league,
      fs.display_name AS team,
      fs.display_name || ' ' || trim(to_char(ld.value, 'FM999990.00'))
        || CASE WHEN fs.units ILIKE '%percent%' THEN '%' ELSE '' END
        || ' (' || to_char(ld.observation_date, 'Mon YYYY') || ')'
        || CASE
             WHEN ld.prior_value IS NULL       THEN ''
             WHEN ld.value > ld.prior_value    THEN ' ▲'
             WHEN ld.value < ld.prior_value    THEN ' ▼'
             ELSE ' —'
           END                                      AS headline,
      NULLIF(
        CASE WHEN ld.prior_value IS NULL THEN ''
             ELSE 'prior ' || trim(to_char(ld.prior_value, 'FM999990.00'))
                  || CASE WHEN fs.units ILIKE '%percent%' THEN '%' ELSE '' END
                  || CASE WHEN ld.value <> ld.prior_value
                          THEN ' ('
                               || CASE WHEN ld.value > ld.prior_value THEN '+' ELSE '' END
                               || trim(to_char(ld.value - ld.prior_value, 'FM999990.00')) || ')'
                          ELSE ' (unchanged)' END
        END, '')                                    AS summary,
      'https://fred.stlouisfed.org/series/' || ld.series_id AS url,
      NULL::text    AS image_url,
      'macro'::text AS item_type,
      ld.first_seen AS published_at
    FROM landed ld
    JOIN fred_series fs ON fs.series_id = ld.series_id
    WHERE ld.first_seen > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Fed' = ANY (p_sources))
  ),
  -- X (Twitter) posts from the tracked-source roster, via TwitterAPI.io
  -- (x_news_queue/x_news_process, this migration). team = '@<author>' for
  -- attribution (the FE shows it as the source line, like 'r/<sub>' on Reddit
  -- rows). Long premium posts are clipped so one tweet can't swamp the reel.
  x_posts AS (
    SELECT
      'X'::text                                        AS source,
      x.league                                         AS league,
      '@' || x.author_handle                           AS team,
      CASE WHEN length(x.title) > 240
           THEN left(x.title, 237) || '…'
           ELSE x.title END                            AS headline,
      NULLIF(array_to_string(ARRAY(
        SELECT jsonb_array_elements_text(x.matched_keywords -> 'hits')
      ), ' · '), '')                                   AS summary,
      x.url                                            AS url,
      NULL::text                                       AS image_url,
      'x_post'::text                                   AS item_type,
      x.created_utc                                    AS published_at
    FROM public.v_x_news_ticker x
    WHERE x.created_utc > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'X' = ANY (p_sources))
  ),
  unioned AS (
    SELECT * FROM espn
    UNION ALL SELECT * FROM transactions
    UNION ALL SELECT * FROM injuries
    UNION ALL SELECT * FROM scores
    UNION ALL SELECT * FROM standings
    UNION ALL SELECT * FROM reddit
    UNION ALL SELECT * FROM broadway
    UNION ALL SELECT * FROM bway_flags
    UNION ALL SELECT * FROM macro
    UNION ALL SELECT * FROM x_posts
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
