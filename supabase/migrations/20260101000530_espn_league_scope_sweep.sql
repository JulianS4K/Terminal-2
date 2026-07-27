-- Migration 20260519180000 · lane:A1 · writes:espn_injury_snapshot_latest+v_event_full_sports+get_team_playoff_context · pre:20260519170000 · auth:operator-approved 2026-05-18
-- (Applied in prod as mig 20260519180002 after column-reorder retries; this is the canonical authored file.)
--
-- Sweep: enforce espn_league + espn_team_id pairing on all remaining
-- cross-league-risky query sites.
--
-- Discovered via audit after PR #246 codified the landmine ("espn_team_id 28
-- = MLB Braves AND an NHL team"). Operator ask: "for espn_team_id first
-- filter to league/sport then team id, should reduce possibility of
-- duplications significantly."
--
-- Audit found 4 sites that reference espn_team_id without espn_league:
--   1. espn_injury_snapshot_latest (VIEW) — defense-in-depth (athlete_id is
--      globally unique in ESPN's catalog, but pairing is still cleaner)
--   2. v_canonical_coverage (VIEW) — counts only (NULL/NOT NULL); no join
--      → no collision risk → no fix needed
--   3. v_event_full_sports (VIEW) — 4 injury subqueries + 2 news subqueries
--      joined on espn_team_id only → REAL collision risk
--   4. get_team_playoff_context (FUNCTION) — espn_event_snapshots filter on
--      home_team_id|away_team_id only → REAL collision risk
--
-- All source tables/views (team_xref, v_espn_injuries_current,
-- v_espn_team_state, v_event_home_away, v_canonical_event, espn_news,
-- espn_injuries_snapshots, espn_event_snapshots) already carry espn_league
-- — no schema changes needed, just join/filter updates.
--
-- Behavior change: per-event injury/news counts and per-team recent results
-- will now exclude rows that incorrectly matched team_id across leagues.
-- Numbers may go DOWN slightly for events whose team_id had cross-league
-- twins (e.g. MLB Atlanta Braves' id 28 has an NHL counterpart). The drop
-- represents previously-wrong data being filtered out.

DROP VIEW IF EXISTS public.espn_injury_snapshot_latest;
DROP VIEW IF EXISTS public.v_event_full_sports;

-- ====================================================================
-- 1. espn_injury_snapshot_latest — DISTINCT ON (league, team, athlete)
-- ====================================================================
CREATE VIEW public.espn_injury_snapshot_latest AS
SELECT DISTINCT ON (espn_league, espn_team_id, athlete_id)
  espn_league,
  espn_team_id,
  athlete_id,
  content_hash,
  status,
  captured_at,
  last_seen_at,
  id
FROM public.espn_injuries_snapshots
WHERE athlete_id IS NOT NULL
ORDER BY espn_league, espn_team_id, athlete_id, captured_at DESC;

GRANT SELECT ON public.espn_injury_snapshot_latest TO anon, authenticated, service_role;

COMMENT ON VIEW public.espn_injury_snapshot_latest IS
  'Latest injury snapshot per (league, team, athlete). A1 2026-05-18: added espn_league to DISTINCT ON key + output — defense-in-depth against cross-league espn_team_id collisions.';

-- ====================================================================
-- 2. v_event_full_sports — league-scope every injury+news subquery + team_state join
-- ====================================================================
CREATE VIEW public.v_event_full_sports AS
SELECT ce.tevo_event_id,
    ce.tevo_name AS event_name,
    ce.event_date,
    ce.tevo_venue_name AS venue_name,
    ce.canonical_label,
    ce.lifecycle_status,
    ce.sources_count,
    ce.espn_event_id,
    ce.sd_event_id,
    ce.sg_event_id,
    hp.home_performer_id,
    hp.home_performer_name,
    hp.home_espn_team_id,
    hp.away_performer_id,
    hp.away_performer_name,
    hp.away_espn_team_id,
    hp.espn_league,
    hp.days_to_event,
    hp.primary_is_home,
    hts.record_summary AS home_record,
    hts.streak AS home_streak,
    hts.win_pct AS home_win_pct,
    ats.record_summary AS away_record,
    ats.streak AS away_streak,
    ats.win_pct AS away_win_pct,
    ( SELECT count(*) FROM v_espn_injuries_current i
       WHERE i.espn_team_id = hp.home_espn_team_id
         AND i.espn_league = hp.espn_league
         AND i.status = 'Out'::text) AS home_injuries_out,
    ( SELECT count(*) FROM v_espn_injuries_current i
       WHERE i.espn_team_id = hp.home_espn_team_id
         AND i.espn_league = hp.espn_league
         AND i.status = 'Day-To-Day'::text) AS home_injuries_dtd,
    ( SELECT count(*) FROM v_espn_injuries_current i
       WHERE i.espn_team_id = hp.away_espn_team_id
         AND i.espn_league = hp.espn_league
         AND i.status = 'Out'::text) AS away_injuries_out,
    ( SELECT count(*) FROM v_espn_injuries_current i
       WHERE i.espn_team_id = hp.away_espn_team_id
         AND i.espn_league = hp.espn_league
         AND i.status = 'Day-To-Day'::text) AS away_injuries_dtd,
    ( SELECT count(*) FROM espn_news n
       WHERE n.espn_team_id = hp.home_espn_team_id
         AND n.espn_league = hp.espn_league
         AND n.published_at > (now() - '24:00:00'::interval)) AS home_news_24h,
    ( SELECT count(*) FROM espn_news n
       WHERE n.espn_team_id = hp.away_espn_team_id
         AND n.espn_league = hp.espn_league
         AND n.published_at > (now() - '24:00:00'::interval)) AS away_news_24h,
    ( SELECT round(percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (listings_snapshots.retail_price::double precision))::numeric, 2)
       FROM listings_snapshots
       WHERE listings_snapshots.event_id = ce.tevo_event_id
         AND listings_snapshots.captured_at > (now() - '24:00:00'::interval)) AS tevo_retail_median,
    ( SELECT count(*) FROM listings_snapshots
       WHERE listings_snapshots.event_id = ce.tevo_event_id
         AND listings_snapshots.captured_at > (now() - '24:00:00'::interval)) AS tevo_listings_count,
    ( SELECT round(percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (listings_snapshots.retail_price::double precision))::numeric, 2)
       FROM listings_snapshots
       WHERE listings_snapshots.event_id = ce.tevo_event_id
         AND listings_snapshots.is_owned
         AND listings_snapshots.captured_at > (now() - '24:00:00'::interval)) AS our_owned_median,
    ( SELECT count(*) FROM listings_snapshots
       WHERE listings_snapshots.event_id = ce.tevo_event_id
         AND listings_snapshots.is_owned
         AND listings_snapshots.captured_at > (now() - '24:00:00'::interval)) AS our_owned_count
   FROM v_canonical_event ce
     LEFT JOIN v_event_home_away hp ON hp.tevo_event_id = ce.tevo_event_id
     LEFT JOIN v_espn_team_state hts ON hts.espn_team_id = hp.home_espn_team_id AND hts.espn_league = hp.espn_league
     LEFT JOIN v_espn_team_state ats ON ats.espn_team_id = hp.away_espn_team_id AND ats.espn_league = hp.espn_league;

GRANT SELECT ON public.v_event_full_sports TO anon, authenticated, service_role;

COMMENT ON VIEW public.v_event_full_sports IS
  'Full event row + ESPN team-state + injury counts + news counts + listings medians. A1 2026-05-18: league-scoped on injury/news subqueries and v_espn_team_state joins. espn_league exposed as a top-level column.';

-- ====================================================================
-- 3. get_team_playoff_context — fetch league + co-filter snapshot reads
-- ====================================================================
CREATE OR REPLACE FUNCTION public.get_team_playoff_context(p_performer_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_espn_team_id text;
  v_espn_league  text;
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
  -- Pull espn_league alongside espn_team_id and use it as a co-filter on
  -- espn_event_snapshots to avoid cross-league team_id collisions.
  SELECT espn_team_id, espn_league, COALESCE(espn_display_name, tevo_name)
    INTO v_espn_team_id, v_espn_league, v_team_name
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
      AND (v_espn_league IS NULL OR s.espn_league = v_espn_league)
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
      LEFT JOIN espn_event_snapshots s ON s.espn_event_id = x.espn_event_id
        AND (v_espn_league IS NULL OR s.espn_league = v_espn_league)
        AND s.state = 'post'
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
$function$;

COMMENT ON FUNCTION public.get_team_playoff_context(bigint) IS
  'Playoff next-game + recent results + series record. A1 2026-05-18: co-filter espn_event_snapshots by (espn_team_id, espn_league) — prevents cross-league team_id collision pollution.';
