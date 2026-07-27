-- ============================================================================
-- Migration 20260509470000 — MLB regular-season game-series detection
--
-- MLB regular season is unique among the leagues we cover: a 3- or 4-game
-- "series" between the same two teams at the same venue across consecutive
-- days is the standard scheduling unit. Other leagues either don't do
-- series at all (NFL = 1 game/week) or only at playoff time (NBA/NHL).
--
-- This migration:
--   (1) mlb_branded_series — reference table of named rivalry series
--       (Subway Series, Battle of Ohio, Freeway Series, etc.)
--   (2) v_mlb_game_series — auto-detects series from `events` by grouping
--       same-matchup, same-venue, consecutive-day events (≤2 day gap).
--
-- The view is read-only; the reference table is hand-maintained as new
-- branded rivalries become relevant. See docs/mlb-game-series-detection.md
-- for the full design rationale + how to extend.
-- ============================================================================

CREATE TABLE IF NOT EXISTS mlb_branded_series (
  branded_name text PRIMARY KEY,
  team_a       text NOT NULL,
  team_b       text NOT NULL,
  notes        text,
  added_at     timestamptz DEFAULT now()
);

COMMENT ON TABLE mlb_branded_series IS
  'Named rivalry series in MLB regular season (Subway Series, Battle of '
  'Ohio, etc.). The view v_mlb_game_series joins on (team_a, team_b) in '
  'either order to apply the brand label to detected series. Hand-maintained '
  'as rivalries gain prominence. See docs/mlb-game-series-detection.md.';

INSERT INTO mlb_branded_series(branded_name, team_a, team_b, notes) VALUES
  ('Subway Series',          'New York Yankees',     'New York Mets',         'Interleague NYC; ref https://en.wikipedia.org/wiki/Subway_Series'),
  ('Battle of Ohio',         'Cleveland Guardians',  'Cincinnati Reds',       'I-71'),
  ('Freeway Series',         'Los Angeles Dodgers',  'Los Angeles Angels',    'I-5'),
  ('Bay Bridge Series',      'San Francisco Giants', 'Oakland Athletics',     'SF Bay Area; A''s pre-Sacramento'),
  ('Crosstown Classic',      'Chicago Cubs',         'Chicago White Sox',     'Also "Windy City Showdown" / "Red Line Series"'),
  ('Citrus Series',          'Miami Marlins',        'Tampa Bay Rays',        'Florida'),
  ('Lone Star Series',       'Houston Astros',       'Texas Rangers',         'Astros moved to AL West in 2013, formalizing the rivalry'),
  ('Beltway Series',         'Baltimore Orioles',    'Washington Nationals',  'I-95 / Acela'),
  ('I-70 Series',            'St. Louis Cardinals',  'Kansas City Royals',    'Also "Show-Me Series" — both Missouri'),
  ('Battle of Pennsylvania', 'Philadelphia Phillies','Pittsburgh Pirates',    'Less prominent but real')
ON CONFLICT (branded_name) DO NOTHING;

-- ============================================================================
-- v_mlb_game_series — detection logic
-- ============================================================================
-- Strategy:
--   1. Filter events to MLB regular-season games (event_type='game' + both
--      teams in our MLB performer set + exclude postseason events which
--      TEvo names with "(Game N, Home Game M)" markers).
--   2. Parse home_team (= primary_performer_name) + away_team (split " at ").
--   3. Gap-and-island analysis: within (home, away, venue), if today's date
--      is more than 2 days after the previous game in that partition, start
--      a new series.
--   4. Group + LEFT JOIN to mlb_branded_series.
-- ============================================================================

CREATE OR REPLACE VIEW v_mlb_game_series AS
WITH mlb_teams AS (
  SELECT DISTINCT pm.name AS team_name
  FROM performer_metadata pm
  JOIN performer_subreddits ps ON ps.tevo_performer_id = pm.performer_id
  WHERE ps.league = 'MLB'
),
parsed AS (
  SELECT
    e.id                    AS tevo_event_id,
    e.name,
    e.occurs_at_local::date AS event_date,
    e.venue_id,
    e.venue_name,
    e.primary_performer_name AS home_team,
    trim(split_part(e.name, ' at ', 1)) AS away_team
  FROM events e
  WHERE e.event_type = 'game'
    AND e.name ILIKE '% at %'
    AND e.name NOT ILIKE '%(Game %'           -- exclude postseason
    AND e.name NOT ILIKE '%(If Necessary%'
    AND e.primary_performer_name IS NOT NULL
    AND e.venue_id IS NOT NULL
    AND e.primary_performer_name IN (SELECT team_name FROM mlb_teams)
),
parsed_filtered AS (
  -- Both teams must be MLB to qualify as a regular-season series
  SELECT p.*
  FROM parsed p
  WHERE p.away_team IN (SELECT team_name FROM mlb_teams)
),
gapped AS (
  SELECT *,
    LAG(event_date) OVER (
      PARTITION BY home_team, away_team, venue_id
      ORDER BY event_date
    ) AS prev_date
  FROM parsed_filtered
),
flagged AS (
  SELECT *,
    CASE
      WHEN prev_date IS NULL OR (event_date - prev_date) > 2 THEN 1
      ELSE 0
    END AS new_series_flag
  FROM gapped
),
numbered AS (
  SELECT *,
    SUM(new_series_flag) OVER (
      PARTITION BY home_team, away_team, venue_id
      ORDER BY event_date
    ) AS series_id
  FROM flagged
)
SELECT
  numbered.home_team,
  numbered.away_team,
  numbered.venue_id,
  max(numbered.venue_name)        AS venue_name,
  min(numbered.event_date)        AS series_start,
  max(numbered.event_date)        AS series_end,
  (max(numbered.event_date) - min(numbered.event_date) + 1)::int AS series_span_days,
  count(*)::int                   AS game_count,
  array_agg(numbered.tevo_event_id ORDER BY numbered.event_date) AS tevo_event_ids,
  (SELECT mbs.branded_name FROM mlb_branded_series mbs
    WHERE (mbs.team_a = numbered.home_team AND mbs.team_b = numbered.away_team)
       OR (mbs.team_b = numbered.home_team AND mbs.team_a = numbered.away_team)
    LIMIT 1) AS branded_series_name
FROM numbered
GROUP BY numbered.home_team, numbered.away_team, numbered.venue_id, numbered.series_id;

COMMENT ON VIEW v_mlb_game_series IS
  'Auto-detects MLB regular-season game series. Each row = one series (3-4 '
  'consecutive games, same matchup, same venue). branded_series_name is '
  'populated when the matchup matches a row in mlb_branded_series. '
  'Excludes postseason (TEvo names those explicitly with "Game N").';

-- Note on indexing: an index on `(occurs_at_local::timestamptz::date)` would
-- speed up the parsed CTE, but that expression is non-IMMUTABLE so Postgres
-- rejects it as an index expression. The view is fast enough at current
-- volumes (~1500 events). Revisit if events table grows past ~50K.
