-- ============================================================================
-- Migration 20260509250000 — ESPN performance away/home per venue
--
-- Joins espn_event_snapshots to TEvo events (via entity_event_map) to get
-- the venue, then aggregates by (team, venue, side). Powers queries like:
--   "How does Atlanta Hawks perform at TD Garden when they're away?"
--   "What's the Celtics' home-court attendance trend?"
--   "Which team has the worst record at this venue?"
--
-- Includes Vegas-actual gap so day-traders can spot venues where teams
-- consistently over/underperform expectations.
-- ============================================================================

-- (1) Per-game flat view: one row per finalized game with venue + both sides
CREATE OR REPLACE VIEW v_espn_game_results AS
SELECT DISTINCT ON (s.espn_event_id)
  s.espn_event_id, s.espn_league, s.captured_at,
  s.state, s.home_team_id, s.away_team_id,
  s.home_score, s.away_score, s.attendance,
  s.spread, s.over_under, s.home_ml, s.away_ml, s.home_win_prob,
  CASE
    WHEN s.home_score IS NULL OR s.away_score IS NULL THEN NULL
    WHEN s.home_score > s.away_score THEN 'home_win'
    WHEN s.away_score > s.home_score THEN 'away_win'
    ELSE 'tie' END AS outcome,
  (s.home_score + s.away_score) AS total_points,
  CASE
    WHEN s.over_under IS NULL OR s.home_score IS NULL THEN NULL
    WHEN (s.home_score + s.away_score) > s.over_under THEN 'over'
    WHEN (s.home_score + s.away_score) < s.over_under THEN 'under'
    ELSE 'push' END AS over_under_outcome,
  eem.tevo_event_id, eem.tevo_venue_id, eem.tevo_venue_name, eem.event_date
FROM espn_event_snapshots s
LEFT JOIN entity_event_map eem ON eem.espn_event_id::text = s.espn_event_id
WHERE s.state = 'post'
ORDER BY s.espn_event_id, s.captured_at DESC;

-- (2) Team performance at venue — both home and away sides
CREATE OR REPLACE VIEW v_team_at_venue_history AS
WITH at_home AS (
  SELECT home_team_id AS espn_team_id, espn_league,
         tevo_venue_id, tevo_venue_name, 'home' AS side,
         espn_event_id, event_date, outcome,
         home_score AS pts_for, away_score AS pts_against,
         attendance, over_under_outcome, home_win_prob
  FROM v_espn_game_results
  WHERE tevo_venue_id IS NOT NULL AND home_team_id IS NOT NULL
),
at_away AS (
  SELECT away_team_id AS espn_team_id, espn_league,
         tevo_venue_id, tevo_venue_name, 'away' AS side,
         espn_event_id, event_date,
         CASE outcome WHEN 'home_win' THEN 'away_loss'
                      WHEN 'away_win' THEN 'away_win'
                      WHEN 'tie' THEN 'tie' END AS outcome,
         away_score AS pts_for, home_score AS pts_against,
         attendance, over_under_outcome,
         (1 - home_win_prob) AS home_win_prob
  FROM v_espn_game_results
  WHERE tevo_venue_id IS NOT NULL AND away_team_id IS NOT NULL
),
combined AS (SELECT * FROM at_home UNION ALL SELECT * FROM at_away)
SELECT
  espn_team_id, espn_league,
  tevo_venue_id, tevo_venue_name, side,
  count(*) AS games_played,
  count(*) FILTER (WHERE outcome IN ('home_win','away_win'))   AS wins,
  count(*) FILTER (WHERE outcome IN ('home_loss','away_loss')) AS losses,
  count(*) FILTER (WHERE outcome = 'tie') AS ties,
  round(avg(pts_for)::numeric, 1)               AS avg_pts_for,
  round(avg(pts_against)::numeric, 1)           AS avg_pts_against,
  round(avg(pts_for - pts_against)::numeric, 1) AS avg_margin,
  round(avg(attendance)::numeric, 0)            AS avg_attendance,
  count(*) FILTER (WHERE over_under_outcome = 'over')  AS overs,
  count(*) FILTER (WHERE over_under_outcome = 'under') AS unders,
  min(event_date) AS earliest, max(event_date) AS latest
FROM combined
GROUP BY espn_team_id, espn_league, tevo_venue_id, tevo_venue_name, side;

-- (3) Last-N-at-venue convenience
CREATE OR REPLACE VIEW v_team_last_n_at_venue AS
SELECT
  espn_team_id, espn_league, tevo_venue_id, tevo_venue_name, side,
  espn_event_id, event_date, outcome, pts_for, pts_against,
  attendance, over_under_outcome,
  row_number() OVER (PARTITION BY espn_team_id, tevo_venue_id, side
                     ORDER BY event_date DESC) AS games_ago
FROM (
  SELECT home_team_id AS espn_team_id, espn_league,
         tevo_venue_id, tevo_venue_name, 'home' AS side,
         espn_event_id, event_date, outcome,
         home_score AS pts_for, away_score AS pts_against,
         attendance, over_under_outcome
  FROM v_espn_game_results WHERE tevo_venue_id IS NOT NULL
  UNION ALL
  SELECT away_team_id, espn_league,
         tevo_venue_id, tevo_venue_name, 'away',
         espn_event_id, event_date,
         CASE outcome WHEN 'home_win' THEN 'away_loss'
                      WHEN 'away_win' THEN 'away_win'
                      WHEN 'tie' THEN 'tie' END,
         away_score, home_score,
         attendance, over_under_outcome
  FROM v_espn_game_results WHERE tevo_venue_id IS NOT NULL
) all_games;

COMMENT ON VIEW v_espn_game_results IS
  'One row per finalized ESPN game, joined to TEvo for venue context. '
  'DISTINCT ON espn_event_id ORDER BY captured_at DESC = latest snap only.';

COMMENT ON VIEW v_team_at_venue_history IS
  '(team, venue, side) aggregates. Power query: "How does the Hawks perform '
  'at TD Garden as away?" Includes vegas total over/under hit rate.';

COMMENT ON VIEW v_team_last_n_at_venue IS
  'Per (team, venue, side), each game with games_ago window. Filter '
  'WHERE games_ago <= 5 for "last 5 games at this venue".';
