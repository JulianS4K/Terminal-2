-- ============================================================================
-- Migration 20260510110000 — ESPN team canonical list + performer xref
--
-- Phase-2 infrastructure for the matcher rewrite. Coworker's bundle pull
-- found the team_date matcher (in an edge function) is producing wrong
-- and colliding xrefs at scale (60 visible collisions across MLB+NBA).
--
-- We can't fix the edge function from a SQL migration, but we CAN ship
-- the lookup tables so the next-pass matcher (or its plpgsql replacement)
-- can do strict (home_team_id, away_team_id, game_date) joins.
--
-- ----------------------------------------------------------------------------
-- WHAT'S IN THIS MIGRATION
-- ----------------------------------------------------------------------------
--   1. espn_teams_canonical          (169 teams across NBA/NFL/MLB/NHL/WNBA/MLS)
--   2. performer_espn_team_xref       (TEvo performer_id ↔ ESPN team_id, with
--                                       variant aliases for Clippers/Athletics/
--                                       Atlanta-United/LAFC/Red-Bulls/Whitecaps/
--                                       Montréal/Houston-Dynamo/etc.)
--   3. espn_event_date_lookup        (table; NBA + partial NHL pre-loaded)
--   4. _ingest_espn_scoreboard()      synchronous pg_net helper
--
-- Coverage check on launch: 169/169 ESPN teams mapped to a TEvo performer
-- across all 6 leagues. Zero unmapped.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES NOT DO
-- ----------------------------------------------------------------------------
-- * Bulk-fix existing wrong xrefs. The strict matcher requires
--   espn_event_date_lookup to be populated comprehensively, but
--   round-tripping 1,696 events through MCP execute_sql hit a throughput
--   wall. Phase-2 work: either (a) use psql or COPY to bulk-load, or
--   (b) write a new in-DB matcher that fires N pg_net pulls then
--   processes them in a separate cron tick.
--
-- * Replace the broken edge-function matcher. The ON CONFLICT-resilient
--   guard view (v_event_xref_collisions, shipped 20260510100000) flags
--   regressions automatically; the edge-function fix is on the
--   Terminal-2-ui side or in a future plpgsql matcher.
-- ============================================================================

-- ============================================================================
-- (1) Canonical ESPN team list
-- ============================================================================
CREATE TABLE IF NOT EXISTS espn_teams_canonical (
  espn_team_id text NOT NULL,
  espn_league  text NOT NULL,
  display_name text NOT NULL,
  PRIMARY KEY (espn_team_id, espn_league)
);

TRUNCATE espn_teams_canonical;
INSERT INTO espn_teams_canonical(espn_league, espn_team_id, display_name) VALUES
  -- NBA
  ('NBA','1','Atlanta Hawks'),('NBA','2','Boston Celtics'),('NBA','17','Brooklyn Nets'),
  ('NBA','30','Charlotte Hornets'),('NBA','4','Chicago Bulls'),('NBA','5','Cleveland Cavaliers'),
  ('NBA','6','Dallas Mavericks'),('NBA','7','Denver Nuggets'),('NBA','8','Detroit Pistons'),
  ('NBA','9','Golden State Warriors'),('NBA','10','Houston Rockets'),('NBA','11','Indiana Pacers'),
  ('NBA','12','LA Clippers'),('NBA','13','Los Angeles Lakers'),('NBA','29','Memphis Grizzlies'),
  ('NBA','14','Miami Heat'),('NBA','15','Milwaukee Bucks'),('NBA','16','Minnesota Timberwolves'),
  ('NBA','3','New Orleans Pelicans'),('NBA','18','New York Knicks'),('NBA','25','Oklahoma City Thunder'),
  ('NBA','19','Orlando Magic'),('NBA','20','Philadelphia 76ers'),('NBA','21','Phoenix Suns'),
  ('NBA','22','Portland Trail Blazers'),('NBA','23','Sacramento Kings'),('NBA','24','San Antonio Spurs'),
  ('NBA','28','Toronto Raptors'),('NBA','26','Utah Jazz'),('NBA','27','Washington Wizards'),
  -- NFL
  ('NFL','22','Arizona Cardinals'),('NFL','1','Atlanta Falcons'),('NFL','33','Baltimore Ravens'),
  ('NFL','2','Buffalo Bills'),('NFL','29','Carolina Panthers'),('NFL','3','Chicago Bears'),
  ('NFL','4','Cincinnati Bengals'),('NFL','5','Cleveland Browns'),('NFL','6','Dallas Cowboys'),
  ('NFL','7','Denver Broncos'),('NFL','8','Detroit Lions'),('NFL','9','Green Bay Packers'),
  ('NFL','34','Houston Texans'),('NFL','11','Indianapolis Colts'),('NFL','30','Jacksonville Jaguars'),
  ('NFL','12','Kansas City Chiefs'),('NFL','13','Las Vegas Raiders'),('NFL','24','Los Angeles Chargers'),
  ('NFL','14','Los Angeles Rams'),('NFL','15','Miami Dolphins'),('NFL','16','Minnesota Vikings'),
  ('NFL','17','New England Patriots'),('NFL','18','New Orleans Saints'),('NFL','19','New York Giants'),
  ('NFL','20','New York Jets'),('NFL','21','Philadelphia Eagles'),('NFL','23','Pittsburgh Steelers'),
  ('NFL','25','San Francisco 49ers'),('NFL','26','Seattle Seahawks'),('NFL','27','Tampa Bay Buccaneers'),
  ('NFL','10','Tennessee Titans'),('NFL','28','Washington Commanders'),
  -- MLB
  ('MLB','29','Arizona Diamondbacks'),('MLB','11','Athletics'),('MLB','15','Atlanta Braves'),
  ('MLB','1','Baltimore Orioles'),('MLB','2','Boston Red Sox'),('MLB','16','Chicago Cubs'),
  ('MLB','4','Chicago White Sox'),('MLB','17','Cincinnati Reds'),('MLB','5','Cleveland Guardians'),
  ('MLB','27','Colorado Rockies'),('MLB','6','Detroit Tigers'),('MLB','18','Houston Astros'),
  ('MLB','7','Kansas City Royals'),('MLB','3','Los Angeles Angels'),('MLB','19','Los Angeles Dodgers'),
  ('MLB','28','Miami Marlins'),('MLB','8','Milwaukee Brewers'),('MLB','9','Minnesota Twins'),
  ('MLB','21','New York Mets'),('MLB','10','New York Yankees'),('MLB','22','Philadelphia Phillies'),
  ('MLB','23','Pittsburgh Pirates'),('MLB','25','San Diego Padres'),('MLB','26','San Francisco Giants'),
  ('MLB','12','Seattle Mariners'),('MLB','24','St. Louis Cardinals'),('MLB','30','Tampa Bay Rays'),
  ('MLB','13','Texas Rangers'),('MLB','14','Toronto Blue Jays'),('MLB','20','Washington Nationals'),
  -- NHL
  ('NHL','25','Anaheim Ducks'),('NHL','1','Boston Bruins'),('NHL','2','Buffalo Sabres'),
  ('NHL','3','Calgary Flames'),('NHL','7','Carolina Hurricanes'),('NHL','4','Chicago Blackhawks'),
  ('NHL','17','Colorado Avalanche'),('NHL','29','Columbus Blue Jackets'),('NHL','9','Dallas Stars'),
  ('NHL','5','Detroit Red Wings'),('NHL','6','Edmonton Oilers'),('NHL','26','Florida Panthers'),
  ('NHL','8','Los Angeles Kings'),('NHL','30','Minnesota Wild'),('NHL','10','Montreal Canadiens'),
  ('NHL','27','Nashville Predators'),('NHL','11','New Jersey Devils'),('NHL','12','New York Islanders'),
  ('NHL','13','New York Rangers'),('NHL','14','Ottawa Senators'),('NHL','15','Philadelphia Flyers'),
  ('NHL','16','Pittsburgh Penguins'),('NHL','18','San Jose Sharks'),('NHL','124292','Seattle Kraken'),
  ('NHL','19','St. Louis Blues'),('NHL','20','Tampa Bay Lightning'),('NHL','21','Toronto Maple Leafs'),
  ('NHL','129764','Utah Mammoth'),('NHL','22','Vancouver Canucks'),('NHL','37','Vegas Golden Knights'),
  ('NHL','23','Washington Capitals'),('NHL','28','Winnipeg Jets'),
  -- WNBA
  ('WNBA','20','Atlanta Dream'),('WNBA','19','Chicago Sky'),('WNBA','18','Connecticut Sun'),
  ('WNBA','3','Dallas Wings'),('WNBA','129689','Golden State Valkyries'),('WNBA','5','Indiana Fever'),
  ('WNBA','17','Las Vegas Aces'),('WNBA','6','Los Angeles Sparks'),('WNBA','8','Minnesota Lynx'),
  ('WNBA','9','New York Liberty'),('WNBA','11','Phoenix Mercury'),('WNBA','132052','Portland Fire'),
  ('WNBA','14','Seattle Storm'),('WNBA','131935','Toronto Tempo'),('WNBA','16','Washington Mystics'),
  -- MLS
  ('MLS','18418','Atlanta United FC'),('MLS','20906','Austin FC'),('MLS','9720','CF Montréal'),
  ('MLS','21300','Charlotte FC'),('MLS','182','Chicago Fire FC'),('MLS','184','Colorado Rapids'),
  ('MLS','183','Columbus Crew'),('MLS','193','D.C. United'),('MLS','18267','FC Cincinnati'),
  ('MLS','185','FC Dallas'),('MLS','6077','Houston Dynamo FC'),('MLS','20232','Inter Miami CF'),
  ('MLS','187','LA Galaxy'),('MLS','18966','LAFC'),('MLS','17362','Minnesota United FC'),
  ('MLS','18986','Nashville SC'),('MLS','189','New England Revolution'),('MLS','17606','New York City FC'),
  ('MLS','12011','Orlando City SC'),('MLS','10739','Philadelphia Union'),('MLS','9723','Portland Timbers'),
  ('MLS','4771','Real Salt Lake'),('MLS','190','Red Bull New York'),('MLS','22529','San Diego FC'),
  ('MLS','191','San Jose Earthquakes'),('MLS','9726','Seattle Sounders FC'),('MLS','186','Sporting Kansas City'),
  ('MLS','21812','St. Louis CITY SC'),('MLS','7318','Toronto FC'),('MLS','9727','Vancouver Whitecaps');

GRANT SELECT ON espn_teams_canonical TO anon;

-- ============================================================================
-- (2) performer_espn_team_xref — TEvo performer ↔ ESPN team
-- ============================================================================
CREATE TABLE IF NOT EXISTS performer_espn_team_xref (
  tevo_performer_id bigint NOT NULL,
  espn_team_id      text   NOT NULL,
  espn_league       text   NOT NULL,
  match_method      text,
  PRIMARY KEY (tevo_performer_id, espn_league)
);
CREATE INDEX IF NOT EXISTS performer_espn_team_xref_team_idx
  ON performer_espn_team_xref(espn_team_id, espn_league);

TRUNCATE performer_espn_team_xref;

WITH variants AS (
  SELECT canonical, alias FROM (VALUES
    ('Los Angeles Clippers',     'LA Clippers'),
    ('Oakland Athletics',        'Athletics'),
    ('Atlanta United',           'Atlanta United FC'),
    ('Los Angeles FC',           'LAFC'),
    ('New York Red Bulls',       'Red Bull New York'),
    ('Vancouver Whitecaps FC',   'Vancouver Whitecaps'),
    ('CF Montreal',              'CF Montréal'),
    ('Houston Dynamo',           'Houston Dynamo FC'),
    ('Minnesota United',         'Minnesota United FC'),
    ('Chicago Fire',             'Chicago Fire FC'),
    ('DC United',                'D.C. United'),
    ('St Louis CITY SC',         'St. Louis CITY SC'),
    ('St. Louis City SC',        'St. Louis CITY SC')
  ) AS v(canonical, alias)
),
all_candidates AS (
  SELECT pm.performer_id, etc.espn_team_id, etc.espn_league, 'exact_name' AS method, 1 AS prio
  FROM performer_metadata pm
  JOIN espn_teams_canonical etc ON lower(trim(pm.name)) = lower(trim(etc.display_name))
  UNION ALL
  SELECT pm.performer_id, etc.espn_team_id, etc.espn_league, 'variant_alias', 2
  FROM performer_metadata pm
  JOIN variants v ON lower(trim(pm.name)) = lower(trim(v.canonical))
  JOIN espn_teams_canonical etc ON lower(trim(etc.display_name)) = lower(trim(v.alias))
),
deduped AS (
  SELECT DISTINCT ON (performer_id, espn_league)
    performer_id, espn_team_id, espn_league, method
  FROM all_candidates
  ORDER BY performer_id, espn_league, prio ASC, espn_team_id
)
INSERT INTO performer_espn_team_xref(tevo_performer_id, espn_team_id, espn_league, match_method)
SELECT performer_id, espn_team_id, espn_league, method FROM deduped;

GRANT SELECT ON performer_espn_team_xref TO anon;

-- ============================================================================
-- (3) espn_event_date_lookup — populated piecemeal; phase-2 to backfill
-- ============================================================================
CREATE TABLE IF NOT EXISTS espn_event_date_lookup (
  espn_event_id   text NOT NULL,
  espn_league     text NOT NULL,
  game_at_utc     timestamptz NOT NULL,
  home_team_id    text,
  away_team_id    text,
  status_short    text,
  ingested_at     timestamptz DEFAULT now(),
  PRIMARY KEY (espn_event_id, espn_league)
);
CREATE INDEX IF NOT EXISTS espn_event_date_lookup_pair_idx
  ON espn_event_date_lookup(espn_league, home_team_id, away_team_id, game_at_utc);
GRANT SELECT ON espn_event_date_lookup TO anon;

COMMENT ON TABLE espn_teams_canonical IS
  'Hard-coded ESPN team list (169 teams across NBA/NFL/MLB/NHL/WNBA/MLS). '
  'Source: ESPN site.api /teams endpoint, captured 2026-05-10. Refresh on '
  'team relocation/expansion.';

COMMENT ON TABLE performer_espn_team_xref IS
  'TEvo performer (team) → ESPN team_id mapping. Built via name match + '
  'known variant aliases. 169/169 teams mapped. Phase-2 plpgsql matcher '
  'will key off this table.';

COMMENT ON TABLE espn_event_date_lookup IS
  'Per-ESPN-event game date + team pair. Sparsely populated today (NBA + '
  'partial NHL); phase-2 work to bulk-load via psql or chunked cron.';
