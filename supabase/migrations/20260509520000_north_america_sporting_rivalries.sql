-- ============================================================================
-- Migration 20260509520000 — North American sporting rivalries reference
--
-- Sister table to mlb_branded_series (mig 470000), but broader scope:
--   - Includes NBA, NFL, MLB, NHL, MLS rivalries
--   - Includes both **branded** rivalries (named series like "Subway
--     Series", "Iron Bowl") AND **unbranded** competitive rivalries
--     (Lakers-Celtics, Yankees-Red Sox, Cowboys-Eagles)
--   - Each row carries Wikipedia URL for chatbot RAG context
--
-- Used by:
--   - Future v_event_rivalry_overlay view (joins events to known rivalries
--     to flag "this is a rivalry game")
--   - get_event_context() AI/RAG bundle — surfaces rivalry context when
--     the matchup is on the list
--
-- mlb_branded_series remains for MLB regular-season series-level branding
-- (Subway Series et al.). This table is the broader "is this a rivalry
-- game" reference.
-- ============================================================================

CREATE TABLE IF NOT EXISTS sporting_rivalries (
  rivalry_name    text PRIMARY KEY,    -- "Lakers-Celtics" or "Subway Series"
  league          text NOT NULL,        -- 'NBA' | 'NFL' | 'MLB' | 'NHL' | 'MLS'
  team_a          text NOT NULL,        -- canonical TEvo performer name
  team_b          text NOT NULL,
  is_branded      boolean DEFAULT false,
  rivalry_intensity text DEFAULT 'high', -- 'historic'|'high'|'medium'
  wikipedia_url   text,
  notes           text,
  added_at        timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sporting_rivalries_league_idx ON sporting_rivalries(league);
CREATE INDEX IF NOT EXISTS sporting_rivalries_team_a_idx ON sporting_rivalries(team_a);
CREATE INDEX IF NOT EXISTS sporting_rivalries_team_b_idx ON sporting_rivalries(team_b);

COMMENT ON TABLE sporting_rivalries IS
  'Cross-league rivalry reference. Both branded (named series) and '
  'unbranded competitive rivalries. Sourced from Wikipedia. Used by AI '
  'context to flag "this is a rivalry game" and by future overlay views. '
  'mlb_branded_series is the MLB-regular-season-only complement.';

-- ============================================================================
-- NBA rivalries (Wikipedia: https://en.wikipedia.org/wiki/List_of_NBA_rivalries)
-- ============================================================================

INSERT INTO sporting_rivalries(rivalry_name, league, team_a, team_b, is_branded, rivalry_intensity, wikipedia_url, notes) VALUES
  ('Lakers vs Celtics',         'NBA', 'Los Angeles Lakers', 'Boston Celtics',
    false, 'historic', 'https://en.wikipedia.org/wiki/Celtics%E2%80%93Lakers_rivalry',
    'Most decorated rivalry in NBA history, 12 Finals matchups'),
  ('Knicks vs Nets',            'NBA', 'New York Knicks', 'Brooklyn Nets',
    false, 'high', 'https://en.wikipedia.org/wiki/Knicks%E2%80%93Nets_rivalry',
    'NYC subway-distance; intensified by Nets Brooklyn move'),
  ('Knicks vs Heat',            'NBA', 'New York Knicks', 'Miami Heat',
    false, 'high', 'https://en.wikipedia.org/wiki/Heat%E2%80%93Knicks_rivalry',
    '90s playoff battles; recent Jimmy Butler era'),
  ('Heat vs Celtics',           'NBA', 'Miami Heat', 'Boston Celtics',
    false, 'high', 'https://en.wikipedia.org/wiki/Celtics%E2%80%93Heat_rivalry',
    'Modern East playoff staple'),
  ('Lakers vs Clippers',        'NBA', 'Los Angeles Lakers', 'Los Angeles Clippers',
    false, 'medium', 'https://en.wikipedia.org/wiki/Clippers%E2%80%93Lakers_rivalry',
    'Hallway series at Crypto.com Arena'),
  ('Warriors vs Cavaliers',     'NBA', 'Golden State Warriors', 'Cleveland Cavaliers',
    false, 'historic', 'https://en.wikipedia.org/wiki/Cavaliers%E2%80%93Warriors_rivalry',
    '4 consecutive Finals 2015-2018'),
  ('Warriors vs Lakers',        'NBA', 'Golden State Warriors', 'Los Angeles Lakers',
    false, 'high', 'https://en.wikipedia.org/wiki/Lakers%E2%80%93Warriors_rivalry',
    'California rivalry, Showtime era'),
  ('Bulls vs Pistons',          'NBA', 'Chicago Bulls', 'Detroit Pistons',
    false, 'historic', 'https://en.wikipedia.org/wiki/Bulls%E2%80%93Pistons_rivalry',
    'Bad Boys era, MJ vs Isiah'),
  ('Pacers vs Knicks',          'NBA', 'Indiana Pacers', 'New York Knicks',
    false, 'high', 'https://en.wikipedia.org/wiki/Knicks%E2%80%93Pacers_rivalry',
    '90s playoff battles, Reggie Miller era'),
  ('Suns vs Lakers',            'NBA', 'Phoenix Suns', 'Los Angeles Lakers',
    false, 'medium', NULL,
    'Frequent playoff matchups, west coast');

-- ============================================================================
-- NFL rivalries (Wikipedia: https://en.wikipedia.org/wiki/List_of_NFL_rivalries)
-- ============================================================================

INSERT INTO sporting_rivalries(rivalry_name, league, team_a, team_b, is_branded, rivalry_intensity, wikipedia_url, notes) VALUES
  ('Cowboys vs Eagles',         'NFL', 'Dallas Cowboys', 'Philadelphia Eagles',
    false, 'historic', 'https://en.wikipedia.org/wiki/Cowboys%E2%80%93Eagles_rivalry',
    'NFC East defining rivalry, twice yearly'),
  ('Cowboys vs Giants',         'NFL', 'Dallas Cowboys', 'New York Giants',
    false, 'historic', 'https://en.wikipedia.org/wiki/Cowboys%E2%80%93Giants_rivalry',
    'Oldest NFC East rivalry'),
  ('Cowboys vs Redskins/Commanders','NFL', 'Dallas Cowboys', 'Washington Commanders',
    false, 'historic', 'https://en.wikipedia.org/wiki/Commanders%E2%80%93Cowboys_rivalry',
    'Thanksgiving staple'),
  ('Packers vs Bears',          'NFL', 'Green Bay Packers', 'Chicago Bears',
    false, 'historic', 'https://en.wikipedia.org/wiki/Bears%E2%80%93Packers_rivalry',
    'Oldest NFL rivalry, 200+ meetings'),
  ('Packers vs Vikings',        'NFL', 'Green Bay Packers', 'Minnesota Vikings',
    false, 'high', 'https://en.wikipedia.org/wiki/Packers%E2%80%93Vikings_rivalry',
    'NFC North divisional'),
  ('Packers vs Lions',          'NFL', 'Green Bay Packers', 'Detroit Lions',
    false, 'high', 'https://en.wikipedia.org/wiki/Lions%E2%80%93Packers_rivalry',
    'Thanksgiving classic'),
  ('Steelers vs Ravens',        'NFL', 'Pittsburgh Steelers', 'Baltimore Ravens',
    false, 'high', 'https://en.wikipedia.org/wiki/Ravens%E2%80%93Steelers_rivalry',
    'Modern AFC North rivalry'),
  ('Steelers vs Browns',        'NFL', 'Pittsburgh Steelers', 'Cleveland Browns',
    false, 'historic', 'https://en.wikipedia.org/wiki/Browns%E2%80%93Steelers_rivalry',
    'Pre-NFL merger origins'),
  ('Steelers vs Bengals',       'NFL', 'Pittsburgh Steelers', 'Cincinnati Bengals',
    false, 'high', 'https://en.wikipedia.org/wiki/Bengals%E2%80%93Steelers_rivalry',
    'AFC North turf war'),
  ('Patriots vs Jets',          'NFL', 'New England Patriots', 'New York Jets',
    false, 'high', 'https://en.wikipedia.org/wiki/Jets%E2%80%93Patriots_rivalry',
    'AFC East historical'),
  ('Patriots vs Dolphins',      'NFL', 'New England Patriots', 'Miami Dolphins',
    false, 'high', 'https://en.wikipedia.org/wiki/Dolphins%E2%80%93Patriots_rivalry',
    'AFC East historic'),
  ('Patriots vs Bills',         'NFL', 'New England Patriots', 'Buffalo Bills',
    false, 'historic', 'https://en.wikipedia.org/wiki/Bills%E2%80%93Patriots_rivalry',
    'AFC East'),
  ('49ers vs Cowboys',          'NFL', 'San Francisco 49ers', 'Dallas Cowboys',
    false, 'historic', 'https://en.wikipedia.org/wiki/49ers%E2%80%93Cowboys_rivalry',
    '90s playoffs, recent revival'),
  ('49ers vs Seahawks',         'NFL', 'San Francisco 49ers', 'Seattle Seahawks',
    false, 'high', 'https://en.wikipedia.org/wiki/49ers%E2%80%93Seahawks_rivalry',
    'NFC West'),
  ('49ers vs Rams',             'NFL', 'San Francisco 49ers', 'Los Angeles Rams',
    false, 'high', 'https://en.wikipedia.org/wiki/49ers%E2%80%93Rams_rivalry',
    'NFC West, California'),
  ('Chiefs vs Raiders',         'NFL', 'Kansas City Chiefs', 'Las Vegas Raiders',
    false, 'historic', 'https://en.wikipedia.org/wiki/Chiefs%E2%80%93Raiders_rivalry',
    'AFC West original AFL'),
  ('Chiefs vs Broncos',         'NFL', 'Kansas City Chiefs', 'Denver Broncos',
    false, 'high', NULL,
    'AFC West'),
  ('Chiefs vs Chargers',        'NFL', 'Kansas City Chiefs', 'Los Angeles Chargers',
    false, 'medium', NULL,
    'AFC West'),
  ('Bills vs Dolphins',         'NFL', 'Buffalo Bills', 'Miami Dolphins',
    false, 'high', NULL,
    'AFC East divisional');

-- ============================================================================
-- MLB rivalries (Wikipedia: https://en.wikipedia.org/wiki/List_of_Major_League_Baseball_rivalries)
-- ============================================================================

INSERT INTO sporting_rivalries(rivalry_name, league, team_a, team_b, is_branded, rivalry_intensity, wikipedia_url, notes) VALUES
  ('Yankees vs Red Sox',        'MLB', 'New York Yankees', 'Boston Red Sox',
    false, 'historic', 'https://en.wikipedia.org/wiki/Yankees%E2%80%93Red_Sox_rivalry',
    'THE rivalry. Curse of the Bambino, 2004 ALCS, etc.'),
  ('Subway Series',             'MLB', 'New York Yankees', 'New York Mets',
    true,  'historic', 'https://en.wikipedia.org/wiki/Subway_Series',
    'Interleague NYC; also detected in mlb_branded_series'),
  ('Dodgers vs Giants',         'MLB', 'Los Angeles Dodgers', 'San Francisco Giants',
    false, 'historic', 'https://en.wikipedia.org/wiki/Dodgers%E2%80%93Giants_rivalry',
    'NL West, Brooklyn-NY origins'),
  ('Cubs vs Cardinals',         'MLB', 'Chicago Cubs', 'St. Louis Cardinals',
    false, 'historic', 'https://en.wikipedia.org/wiki/Cardinals%E2%80%93Cubs_rivalry',
    'NL Central, oldest NL rivalry'),
  ('Cubs vs White Sox / Crosstown Classic','MLB', 'Chicago Cubs', 'Chicago White Sox',
    true,  'high', 'https://en.wikipedia.org/wiki/Cubs%E2%80%93White_Sox_rivalry',
    'Chicago crosstown; also in mlb_branded_series'),
  ('Yankees vs Mets',           'MLB', 'New York Yankees', 'New York Mets',
    false, 'high', NULL,
    'Same as Subway Series — alias for chatbot disambiguation'),
  ('Astros vs Rangers / Lone Star Series','MLB', 'Houston Astros', 'Texas Rangers',
    true,  'high', 'https://en.wikipedia.org/wiki/Astros%E2%80%93Rangers_rivalry',
    'Texas; also in mlb_branded_series'),
  ('Reds vs Guardians / Battle of Ohio',  'MLB', 'Cincinnati Reds', 'Cleveland Guardians',
    true,  'medium', 'https://en.wikipedia.org/wiki/Battle_of_Ohio',
    'Also in mlb_branded_series'),
  ('Cardinals vs Royals / I-70 Series',   'MLB', 'St. Louis Cardinals', 'Kansas City Royals',
    true,  'medium', 'https://en.wikipedia.org/wiki/I-70_Series',
    'Also in mlb_branded_series; 1985 World Series'),
  ('Dodgers vs Angels / Freeway Series',  'MLB', 'Los Angeles Dodgers', 'Los Angeles Angels',
    true,  'medium', 'https://en.wikipedia.org/wiki/Freeway_Series',
    'I-5; also in mlb_branded_series'),
  ('Giants vs Athletics / Bay Bridge Series','MLB', 'San Francisco Giants', 'Oakland Athletics',
    true,  'medium', 'https://en.wikipedia.org/wiki/Bay_Bridge_Series',
    'Disrupted by Athletics Sacramento move'),
  ('Phillies vs Mets',          'MLB', 'Philadelphia Phillies', 'New York Mets',
    false, 'high', 'https://en.wikipedia.org/wiki/Mets%E2%80%93Phillies_rivalry',
    'NL East'),
  ('Braves vs Mets',            'MLB', 'Atlanta Braves', 'New York Mets',
    false, 'high', 'https://en.wikipedia.org/wiki/Braves%E2%80%93Mets_rivalry',
    'NL East, late 90s playoff battles'),
  ('Braves vs Phillies',        'MLB', 'Atlanta Braves', 'Philadelphia Phillies',
    false, 'high', 'https://en.wikipedia.org/wiki/Braves%E2%80%93Phillies_rivalry',
    'NL East'),
  ('Yankees vs Astros',         'MLB', 'New York Yankees', 'Houston Astros',
    false, 'high', NULL,
    'Modern AL rivalry, sign-stealing era'),
  ('Brewers vs Cubs',           'MLB', 'Milwaukee Brewers', 'Chicago Cubs',
    false, 'medium', NULL,
    'NL Central');

-- ============================================================================
-- NHL rivalries (Wikipedia: https://en.wikipedia.org/wiki/List_of_NHL_rivalries)
-- ============================================================================

INSERT INTO sporting_rivalries(rivalry_name, league, team_a, team_b, is_branded, rivalry_intensity, wikipedia_url, notes) VALUES
  ('Rangers vs Islanders',      'NHL', 'New York Rangers', 'New York Islanders',
    false, 'historic', 'https://en.wikipedia.org/wiki/Islanders%E2%80%93Rangers_rivalry',
    'Battle of New York'),
  ('Rangers vs Devils',         'NHL', 'New York Rangers', 'New Jersey Devils',
    false, 'high', 'https://en.wikipedia.org/wiki/Devils%E2%80%93Rangers_rivalry',
    'Hudson River, Metropolitan Division'),
  ('Bruins vs Canadiens',       'NHL', 'Boston Bruins', 'Montreal Canadiens',
    false, 'historic', 'https://en.wikipedia.org/wiki/Bruins%E2%80%93Canadiens_rivalry',
    'Original Six, oldest NHL rivalry, 700+ meetings'),
  ('Bruins vs Maple Leafs',     'NHL', 'Boston Bruins', 'Toronto Maple Leafs',
    false, 'historic', 'https://en.wikipedia.org/wiki/Bruins%E2%80%93Maple_Leafs_rivalry',
    'Original Six'),
  ('Maple Leafs vs Canadiens',  'NHL', 'Toronto Maple Leafs', 'Montreal Canadiens',
    false, 'historic', 'https://en.wikipedia.org/wiki/Canadiens%E2%80%93Maple_Leafs_rivalry',
    'Original Six, Battle of Ontario-Quebec'),
  ('Penguins vs Capitals',      'NHL', 'Pittsburgh Penguins', 'Washington Capitals',
    false, 'high', 'https://en.wikipedia.org/wiki/Capitals%E2%80%93Penguins_rivalry',
    'Crosby vs Ovechkin'),
  ('Penguins vs Flyers',        'NHL', 'Pittsburgh Penguins', 'Philadelphia Flyers',
    false, 'high', 'https://en.wikipedia.org/wiki/Flyers%E2%80%93Penguins_rivalry',
    'Battle of Pennsylvania'),
  ('Flames vs Oilers / Battle of Alberta','NHL', 'Calgary Flames', 'Edmonton Oilers',
    true,  'historic', 'https://en.wikipedia.org/wiki/Battle_of_Alberta',
    'Provincial rivalry, 80s dynasty era'),
  ('Senators vs Maple Leafs / Battle of Ontario','NHL', 'Ottawa Senators', 'Toronto Maple Leafs',
    true,  'high', 'https://en.wikipedia.org/wiki/Battle_of_Ontario',
    'Ontario provincial'),
  ('Avalanche vs Red Wings',    'NHL', 'Colorado Avalanche', 'Detroit Red Wings',
    false, 'historic', 'https://en.wikipedia.org/wiki/Avalanche%E2%80%93Red_Wings_rivalry',
    'Late 90s blood feud'),
  ('Blackhawks vs Red Wings',   'NHL', 'Chicago Blackhawks', 'Detroit Red Wings',
    false, 'historic', 'https://en.wikipedia.org/wiki/Blackhawks%E2%80%93Red_Wings_rivalry',
    'Original Six'),
  ('Sharks vs Kings',           'NHL', 'San Jose Sharks', 'Los Angeles Kings',
    false, 'medium', NULL,
    'California Pacific Division'),
  ('Kings vs Ducks / Freeway Faceoff','NHL', 'Los Angeles Kings', 'Anaheim Ducks',
    true,  'medium', 'https://en.wikipedia.org/wiki/Freeway_Faceoff',
    'Southern California');

-- ============================================================================
-- MLS rivalries (Wikipedia: https://en.wikipedia.org/wiki/List_of_Major_League_Soccer_rivalries)
-- ============================================================================

INSERT INTO sporting_rivalries(rivalry_name, league, team_a, team_b, is_branded, rivalry_intensity, wikipedia_url, notes) VALUES
  ('LAFC vs LA Galaxy / El Trafico','MLS', 'Los Angeles FC', 'LA Galaxy',
    true,  'high', 'https://en.wikipedia.org/wiki/El_Tr%C3%A1fico',
    'LA crosstown'),
  ('NYCFC vs Red Bulls / Hudson River Derby','MLS', 'New York City FC', 'New York Red Bulls',
    true,  'high', 'https://en.wikipedia.org/wiki/Hudson_River_Derby',
    'NYC metropolitan'),
  ('Sounders vs Timbers / Cascadia Cup','MLS', 'Seattle Sounders FC', 'Portland Timbers',
    true,  'historic', 'https://en.wikipedia.org/wiki/Cascadia_Cup',
    '3-team trophy with Vancouver'),
  ('Sounders vs Whitecaps / Cascadia Cup','MLS', 'Seattle Sounders FC', 'Vancouver Whitecaps FC',
    true,  'high', 'https://en.wikipedia.org/wiki/Cascadia_Cup',
    'Pacific NW'),
  ('Timbers vs Whitecaps / Cascadia Cup', 'MLS', 'Portland Timbers', 'Vancouver Whitecaps FC',
    true,  'high', 'https://en.wikipedia.org/wiki/Cascadia_Cup',
    'Pacific NW'),
  ('Atlanta United vs Orlando City','MLS', 'Atlanta United', 'Orlando City SC',
    false, 'high', 'https://en.wikipedia.org/wiki/Atlanta_United_FC%E2%80%93Orlando_City_SC_rivalry',
    'Southeast'),
  ('Inter Miami vs Orlando City','MLS', 'Inter Miami CF', 'Orlando City SC',
    false, 'high', NULL,
    'Florida derby'),
  ('Sporting KC vs FC Dallas',  'MLS', 'Sporting Kansas City', 'FC Dallas',
    false, 'medium', NULL,
    'Original MLS, central rivalry'),
  ('Toronto FC vs Montreal',    'MLS', 'Toronto FC', 'CF Montreal',
    false, 'high', 'https://en.wikipedia.org/wiki/Canadian_Classique',
    'Canadian Classique'),
  ('Chicago Fire vs Columbus Crew','MLS', 'Chicago Fire FC', 'Columbus Crew',
    false, 'high', NULL,
    'Trillium Cup');

-- ============================================================================
-- Helper view: rivalry overlay on events
-- ============================================================================

CREATE OR REPLACE VIEW v_rivalry_events AS
WITH parsed AS (
  SELECT
    e.id AS tevo_event_id,
    e.name,
    e.occurs_at_local::date AS event_date,
    e.venue_name,
    e.primary_performer_name AS home_team,
    trim(split_part(e.name, ' at ', 1)) AS away_team
  FROM events e
  WHERE e.event_type = 'game'
    AND e.name ILIKE '% at %'
    AND e.primary_performer_name IS NOT NULL
)
SELECT
  p.tevo_event_id, p.name, p.event_date, p.venue_name,
  p.home_team, p.away_team,
  sr.rivalry_name, sr.league, sr.is_branded, sr.rivalry_intensity,
  sr.wikipedia_url, sr.notes
FROM parsed p
JOIN sporting_rivalries sr
  ON (sr.team_a = p.home_team AND sr.team_b = p.away_team)
  OR (sr.team_b = p.home_team AND sr.team_a = p.away_team);

COMMENT ON VIEW v_rivalry_events IS
  'Events that match a known rivalry. Use this to overlay "Rivalry Game" '
  'badge on any event UI surface. Returns all rivalries that match either '
  'team-direction (home-away or away-home).';
