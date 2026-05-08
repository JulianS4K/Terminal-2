-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-07 21:48 UTC.
--
-- Enrich get_team_context with playoff series context, recent results, next game.
-- Both broker terminal and retail chatbot consume this.
-- Derived from event names + espn_event_snapshots + event_xref + performer_home_venues.

CREATE OR REPLACE FUNCTION classify_playoff_stage(p_event_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_event_name ILIKE '%nba finals%'
      OR p_event_name ILIKE '%stanley cup final%'
      OR p_event_name ILIKE '%world series%'
      OR p_event_name ILIKE '%super bowl%'                            THEN 'finals'
    WHEN p_event_name ILIKE '%conference final%'
      OR p_event_name ILIKE '%afc championship%'
      OR p_event_name ILIKE '%nfc championship%'
      OR p_event_name ILIKE '%alcs%' OR p_event_name ILIKE '%nlcs%'
      OR p_event_name ILIKE '%round 3%'                               THEN 'conference_finals'
    WHEN p_event_name ILIKE '%semifinal%'
      OR p_event_name ILIKE '%divisional%'
      OR p_event_name ILIKE '%alds%' OR p_event_name ILIKE '%nlds%'
      OR p_event_name ILIKE '%round 2%'                               THEN 'semifinals'
    WHEN p_event_name ILIKE '%first round%'
      OR p_event_name ILIKE '%round 1%'
      OR p_event_name ILIKE '%wild card%'                             THEN 'first_round'
    WHEN p_event_name ILIKE '%playoff%'                               THEN 'playoffs'
    WHEN p_event_name ~* 'game\s+\d+' AND p_event_name NOT ILIKE '%preseason%' THEN 'playoffs'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION extract_game_number(p_event_name text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT (regexp_match(p_event_name, '\mGame\s+(\d+)\M', 'i'))[1]::int;
$$;

CREATE OR REPLACE FUNCTION extract_opponent(p_event_name text, p_team_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  WITH stripped AS (
    SELECT regexp_replace(p_event_name, '\s*\([^)]*\)', '', 'g') AS s
  )
  SELECT NULLIF(trim(CASE
    WHEN s ILIKE '%' || p_team_name || ' at %' THEN
      regexp_replace(s, '^.*' || p_team_name || ' at\s+', '', 'i')
    WHEN s ILIKE '% at ' || p_team_name || '%' THEN
      regexp_replace(s, '\s+at\s+' || p_team_name || '.*$', '', 'i')
    WHEN s ILIKE '%' || p_team_name || ' vs %' THEN
      regexp_replace(s, '^.*' || p_team_name || ' vs\.?\s+', '', 'i')
    WHEN s ILIKE '% vs ' || p_team_name || '%' THEN
      regexp_replace(s, '\s+vs\.?\s+' || p_team_name || '.*$', '', 'i')
    ELSE NULL
  END), '')
  FROM stripped;
$$;

CREATE OR REPLACE FUNCTION get_team_playoff_context(p_performer_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_espn_team_id text;
  v_team_name    text;
  v_home_venue_id bigint;
  v_next        jsonb;
  v_recent      jsonb;
  v_series      jsonb;
  v_series_wins int;
  v_series_losses int;
  v_opponent    text;
  v_stage       text;
  v_game_number int;
BEGIN
  SELECT espn_team_id, COALESCE(espn_display_name, tevo_name)
    INTO v_espn_team_id, v_team_name
  FROM team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1;
  SELECT venue_id INTO v_home_venue_id FROM performer_home_venues WHERE performer_id = p_performer_id;

  SELECT jsonb_build_object(
    'event_id', e.id,
    'name', e.name,
    'occurs_at_local', e.occurs_at_local,
    'venue', e.venue_name,
    'is_home', (v_home_venue_id IS NOT NULL AND e.venue_id = v_home_venue_id),
    'opponent', extract_opponent(e.name, COALESCE(v_team_name, e.primary_performer_name)),
    'series_stage', classify_playoff_stage(e.name),
    'game_number', extract_game_number(e.name),
    'if_necessary', (e.name ILIKE '%(if necessary)%' OR e.name ILIKE '%date tbd%')
  )
  INTO v_next
  FROM events e
  WHERE e.primary_performer_id = p_performer_id
    AND e.occurs_at_local::date >= current_date
  ORDER BY e.occurs_at_local::timestamptz ASC
  LIMIT 1;

  v_stage := v_next ->> 'series_stage';
  v_opponent := v_next ->> 'opponent';
  v_game_number := (v_next ->> 'game_number')::int;

  WITH my_games AS (
    SELECT s.captured_at, s.home_team_id, s.away_team_id, s.home_score, s.away_score,
           e.name AS evt_name, e.occurs_at_local
    FROM espn_event_snapshots s
    JOIN event_xref x ON x.espn_event_id = s.espn_event_id
    JOIN events e ON e.id = x.tevo_event_id
    WHERE (s.home_team_id = v_espn_team_id OR s.away_team_id = v_espn_team_id)
      AND s.state = 'post'
      AND s.home_score IS NOT NULL AND s.away_score IS NOT NULL
    ORDER BY s.captured_at DESC LIMIT 5
  )
  SELECT jsonb_agg(jsonb_build_object(
    'date', occurs_at_local, 'name', evt_name,
    'home_team_id', home_team_id, 'away_team_id', away_team_id,
    'home_score', home_score, 'away_score', away_score,
    'result', CASE
      WHEN home_team_id = v_espn_team_id AND home_score > away_score THEN 'W'
      WHEN home_team_id = v_espn_team_id AND home_score < away_score THEN 'L'
      WHEN away_team_id = v_espn_team_id AND away_score > home_score THEN 'W'
      WHEN away_team_id = v_espn_team_id AND away_score < home_score THEN 'L'
      ELSE NULL END,
    'team_score', CASE
      WHEN home_team_id = v_espn_team_id THEN home_score
      WHEN away_team_id = v_espn_team_id THEN away_score ELSE NULL END,
    'opp_score', CASE
      WHEN home_team_id = v_espn_team_id THEN away_score
      WHEN away_team_id = v_espn_team_id THEN home_score ELSE NULL END
  ))
  INTO v_recent FROM my_games;

  IF v_opponent IS NOT NULL AND v_stage IS NOT NULL THEN
    WITH series_games AS (
      SELECT e.id, e.name, e.occurs_at_local,
             extract_game_number(e.name) AS game_n,
             classify_playoff_stage(e.name) AS stage
      FROM events e
      WHERE e.primary_performer_id = p_performer_id
        AND classify_playoff_stage(e.name) = v_stage
        AND (e.name ILIKE '%' || v_opponent || '%')
    ),
    series_results AS (
      SELECT sg.id, sg.name, sg.game_n, s.home_team_id, s.away_team_id, s.home_score, s.away_score,
             s.state
      FROM series_games sg
      LEFT JOIN event_xref x ON x.tevo_event_id = sg.id
      LEFT JOIN espn_event_snapshots s ON s.espn_event_id = x.espn_event_id AND s.state = 'post'
    )
    SELECT
      count(*) FILTER (
        WHERE state = 'post'
          AND ((home_team_id = v_espn_team_id AND home_score > away_score)
            OR (away_team_id = v_espn_team_id AND away_score > home_score))
      )::int,
      count(*) FILTER (
        WHERE state = 'post'
          AND ((home_team_id = v_espn_team_id AND home_score < away_score)
            OR (away_team_id = v_espn_team_id AND away_score < home_score))
      )::int
    INTO v_series_wins, v_series_losses
    FROM series_results;

    v_series := jsonb_build_object(
      'opponent', v_opponent,
      'stage', v_stage,
      'next_game_number', v_game_number,
      'series_record', jsonb_build_object(
        'wins', COALESCE(v_series_wins, 0),
        'losses', COALESCE(v_series_losses, 0),
        'summary', COALESCE(v_series_wins, 0) || '-' || COALESCE(v_series_losses, 0)
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'next_game', v_next,
    'recent_results', COALESCE(v_recent, '[]'::jsonb),
    'series', v_series
  );
END
$fn$;

DROP FUNCTION IF EXISTS get_team_context(bigint);

CREATE OR REPLACE FUNCTION get_team_context(p_performer_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  WITH x AS (
    SELECT espn_team_id, espn_league, espn_slug, tevo_name, espn_display_name, espn_abbr
    FROM team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1
  ),
  latest_snap AS (
    SELECT s.* FROM espn_team_snapshots s, x
    WHERE s.espn_team_id = x.espn_team_id
    ORDER BY s.captured_at DESC LIMIT 1
  ),
  inj_open AS (
    SELECT count(*) AS n FROM espn_injuries_snapshots i, x
    WHERE i.espn_team_id = x.espn_team_id
      AND i.captured_at >= now() - interval '14 days'
  ),
  recent_news AS (
    SELECT jsonb_agg(jsonb_build_object('headline', headline, 'published_at', published_at, 'url', url)) AS items
    FROM (
      SELECT n.headline, n.published_at, n.url FROM espn_news n, x
      WHERE n.espn_team_id = x.espn_team_id ORDER BY n.published_at DESC NULLS LAST LIMIT 5
    ) recent
  ),
  roster_size AS (
    SELECT count(*)::int AS n FROM espn_athletes a, x
    WHERE a.espn_team_id = x.espn_team_id AND a.status = 'active'
  )
  SELECT jsonb_build_object(
    'performer_id', p_performer_id,
    'team', (SELECT jsonb_build_object(
        'espn_team_id', espn_team_id, 'espn_league', espn_league,
        'name', COALESCE(espn_display_name, tevo_name), 'abbr', espn_abbr) FROM x),
    'standing', (SELECT jsonb_build_object(
        'record', record_summary, 'win_pct', win_pct, 'games_back', games_back,
        'streak', streak, 'standing_summary', standing_summary,
        'playoff_seed', playoff_seed, 'conference_rank', conference_rank,
        'division_rank', division_rank, 'as_of', captured_at) FROM latest_snap),
    'playoff', get_team_playoff_context(p_performer_id),
    'recent_news', (SELECT items FROM recent_news),
    'open_injuries_14d', (SELECT n FROM inj_open),
    'roster_size', (SELECT n FROM roster_size)
  );
$fn$;

COMMENT ON FUNCTION get_team_playoff_context IS
  'Playoff series context for a performer: next game (with stage + game number + opponent + home/away), recent W/L results, current series record (W-L vs same opponent in same stage). Stage classifier handles NBA/NHL/MLB/NFL playoff naming.';
COMMENT ON FUNCTION get_team_context IS
  'Full team context for both products: standings, playoff series + next game, recent news, injury count, roster size. Single shared helper.';
