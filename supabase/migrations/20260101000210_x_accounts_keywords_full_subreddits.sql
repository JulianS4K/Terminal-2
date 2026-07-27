-- ============================================================================
-- Migration 20260509420000 — X-account roster + news keywords + 6-sports+F1 subs
--
-- Per directive: map reddit subs to all sports and their performers for 6 major
-- sports + F1; ingest the X.com handles + keywords from the news-ticker
-- spreadsheet as informational context (same bucket as performer_wikipedia)
-- for future chatbot/AI consumers — NOT as SQL analytics targets.
--
-- WHY THIS MATTERS:
--   - X/Twitter has no free read API. The handles in important_x_accounts
--     are NOT pulled directly. They're stored as ground truth so when a
--     Reddit post quotes (or copies from) a tweet by Wojnarowski / Schefter /
--     etc., the chatbot can recognize the source and weight accordingly.
--   - Reddit RSS posts that match keywords (injury, trade, scratched, tour
--     announcement, presale, etc.) get flagged in v_reddit_important_recent
--     for the chatbot to surface as "important news."
--
-- WHAT'S IN THIS MIGRATION:
--   (1) important_x_accounts table — 428 handles from spreadsheet
--   (2) news_keywords table — sports + broadway + concert keyword sets
--   (3) general_subreddits table — leaguewide subs not pinned to a performer
--   (4) Expanded performer_subreddits — 176 team-subreddit pairs across
--       NBA + NFL + MLB + NHL + WNBA + MLS + F1
--   (5) match_news_keywords(text) — returns array of matched categories
--   (6) v_reddit_important_recent — Reddit posts in last 24h with hits
--   (7) Extended get_event_context — adds important_news + x_accounts_known
--
-- All 6 sports + F1 covered. Reddit data flows through performer_subreddits
-- the same way it has been; this migration just expands the seed and adds
-- importance scoring layer on top.
-- ============================================================================

-- ============================================================================
-- (1) important_x_accounts — store every X handle as informational context
-- ============================================================================

CREATE TABLE IF NOT EXISTS important_x_accounts (
  handle         text PRIMARY KEY,            -- e.g. '@wojespn'
  name           text NOT NULL,               -- e.g. 'Adrian Wojnarowski'
  account_type   text NOT NULL,               -- 'insider' | 'beat_reporter' | 'team_official' |
                                              -- 'league_official' | 'broadway_*' | 'concert_*'
  league         text,                        -- 'NBA' | 'NFL' | 'MLB' | 'NHL' | 'WNBA' | 'MLS' |
                                              -- 'F1' | 'Broadway' | 'Concerts' | NULL
  team_name      text,                        -- TEvo-style team name when applicable
  priority       text DEFAULT 'medium',       -- 'high' | 'medium' | 'low'
  added_at       timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS important_x_accounts_league_idx ON important_x_accounts(league);
CREATE INDEX IF NOT EXISTS important_x_accounts_team_idx   ON important_x_accounts(team_name);
CREATE INDEX IF NOT EXISTS important_x_accounts_type_idx   ON important_x_accounts(account_type);

COMMENT ON TABLE important_x_accounts IS
  'Roster of X.com handles by category (insiders, beat reporters, teams, leagues, '
  'Broadway shows/producers/reporters, concert venues/promoters/artists). '
  'Phase 1 cannot pull X directly — free X read API is closed post-Musk. '
  'This table is INFORMATIONAL CONTEXT for AI/RAG consumers: when the chatbot '
  'sees a Reddit post quoting a known insider, it can recognize the source '
  'and elevate priority. Bucket: same intent as performer_wikipedia — context '
  'for prompts, not SQL analytics.';

-- ============================================================================
-- (2) news_keywords — what makes a post "important"
-- ============================================================================

CREATE TABLE IF NOT EXISTS news_keywords (
  keyword     text PRIMARY KEY,
  category    text NOT NULL,    -- 'sports_injury'|'sports_transactions'|'broadway_status'|
                                -- 'concert_tour'|'concert_onsale'|'concert_venue_change'
  weight      numeric(3,2) DEFAULT 1.0,
  notes       text
);

INSERT INTO news_keywords(keyword, category, weight, notes) VALUES
  -- Sports injury / lineup status
  ('injury',       'sports_injury',     1.5, 'Direct injury mention'),
  ('injured',      'sports_injury',     1.5, NULL),
  ('out',          'sports_injury',     1.0, 'Common but high-recall'),
  ('scratched',    'sports_injury',     1.5, 'Hockey/baseball scratch'),
  ('day-to-day',   'sports_injury',     1.0, NULL),
  ('questionable', 'sports_injury',     1.0, NULL),
  ('doubtful',     'sports_injury',     1.2, NULL),
  ('IL',           'sports_injury',     1.0, 'Injured List (MLB)'),
  ('IR',           'sports_injury',     1.0, 'Injured Reserve (NFL)'),
  ('LTIR',         'sports_injury',     1.2, 'Long-term IR (NHL)'),
  ('ruled out',    'sports_injury',     1.5, NULL),
  ('placed on',    'sports_injury',     1.0, 'IL/IR placement phrasing'),
  ('60-day IL',    'sports_injury',     1.5, NULL),
  -- Sports transactions
  ('trade',        'sports_transactions', 1.5, NULL),
  ('traded',       'sports_transactions', 1.5, NULL),
  ('signing',      'sports_transactions', 1.5, NULL),
  ('signed',       'sports_transactions', 1.3, NULL),
  ('claim',        'sports_transactions', 1.2, NULL),
  ('waived',       'sports_transactions', 1.2, NULL),
  ('lineup',       'sports_transactions', 1.0, NULL),
  ('starting',     'sports_transactions', 1.0, NULL),
  ('promoted',     'sports_transactions', 1.0, NULL),
  ('called up',    'sports_transactions', 1.0, NULL),
  -- Broadway status
  ('closing',           'broadway_status', 1.5, 'Show closing'),
  ('final performance', 'broadway_status', 1.5, NULL),
  ('extended',          'broadway_status', 1.3, 'Run extension'),
  ('limited run',       'broadway_status', 1.3, NULL),
  ('casting announcement','broadway_status', 1.2, NULL),
  ('national tour',     'broadway_status', 1.2, NULL),
  ('return engagement', 'broadway_status', 1.2, NULL),
  -- Concert / tour
  ('tour announcement',  'concert_tour',   1.5, NULL),
  ('second show added',  'concert_onsale', 1.5, NULL),
  ('new date added',     'concert_onsale', 1.5, NULL),
  ('presale announced',  'concert_onsale', 1.3, NULL),
  ('general onsale',     'concert_onsale', 1.3, NULL),
  ('venue change',       'concert_venue_change', 1.5, NULL),
  ('festival lineup',    'concert_tour',   1.2, NULL),
  ('residency announced','concert_tour',   1.5, NULL)
ON CONFLICT (keyword) DO NOTHING;

COMMENT ON TABLE news_keywords IS
  'Keywords that signal a Reddit post is "important news" worth surfacing to '
  'the chatbot / future UI. Weights: 1.5 = strong signal, 1.0 = weak. '
  'Per-category so a Broadway sub does not match sports keywords accidentally.';

-- ============================================================================
-- (3) general_subreddits — leaguewide / cross-team feeds
-- ============================================================================

CREATE TABLE IF NOT EXISTS general_subreddits (
  subreddit   text PRIMARY KEY,
  league      text NOT NULL,
  scope       text DEFAULT 'league_general',  -- 'league_general'|'league_news'|'sport_general'
  notes       text
);

INSERT INTO general_subreddits(subreddit, league, scope, notes) VALUES
  ('nba',           'NBA', 'league_general', NULL),
  ('nbadiscussion', 'NBA', 'league_general', NULL),
  ('nfl',           'NFL', 'league_general', NULL),
  ('NFLDraft',      'NFL', 'league_general', NULL),
  ('baseball',      'MLB', 'league_general', NULL),
  ('mlbthebigshow', 'MLB', 'league_general', NULL),
  ('hockey',        'NHL', 'league_general', NULL),
  ('nhl',           'NHL', 'league_general', NULL),
  ('wnba',          'WNBA','league_general', NULL),
  ('MLS',           'MLS', 'league_general', NULL),
  ('formula1',      'F1',  'league_general', 'Main F1 sub'),
  ('F1Technical',   'F1',  'league_news',    NULL),
  ('formuladank',   'F1',  'league_general', 'Memes, but high signal volume'),
  ('CollegeBasketball','NCAA-MBB','league_general', NULL),
  ('CFB',           'NCAA-FB','league_general',  NULL),
  ('Broadway',      'Broadway','league_general', NULL),
  ('musicals',      'Broadway','league_general', NULL),
  ('Music',         'Concerts','league_general', NULL),
  ('LiveMusic',     'Concerts','league_general', NULL),
  ('Festivals',     'Concerts','league_general', NULL)
ON CONFLICT (subreddit) DO NOTHING;

COMMENT ON TABLE general_subreddits IS
  'Leaguewide / cross-team subreddits not tied to a specific performer. '
  'Used for general-sentiment pulls (e.g. /r/nba breaking news that does '
  'not yet have a team-specific tag). Phase 2 cron can fan out to these.';


-- ============================================================================
-- (4a) Seed important_x_accounts (428 handles from spreadsheet)
-- ============================================================================
INSERT INTO important_x_accounts(handle, name, account_type, league, team_name, priority) VALUES
  ('@wojespn', 'Adrian Wojnarowski', 'insider', NULL, NULL, 'high'),
  ('@ShamsCharania', 'Shams Charania', 'insider', NULL, NULL, 'high'),
  ('@AdamSchefter', 'Adam Schefter', 'insider', NULL, NULL, 'high'),
  ('@RapSheet', 'Ian Rapoport', 'insider', NULL, NULL, 'high'),
  ('@JeffPassan', 'Jeff Passan', 'insider', NULL, NULL, 'high'),
  ('@Ken_Rosenthal', 'Ken Rosenthal', 'insider', NULL, NULL, 'high'),
  ('@PeteThamel', 'Pete Thamel', 'insider', NULL, NULL, 'high'),
  ('@Brett_McMurphy', 'Brett McMurphy', 'insider', NULL, NULL, 'high'),
  ('@WindhorstESPN', 'Brian Windhorst', 'insider', NULL, NULL, 'high'),
  ('@TheSteinLine', 'Marc Stein', 'insider', NULL, NULL, 'high'),
  ('@TomPelissero', 'Tom Pelissero', 'insider', NULL, NULL, 'high'),
  ('@MikeGarafolo', 'Mike Garafolo', 'insider', NULL, NULL, 'high'),
  ('@FieldYates', 'Field Yates', 'insider', NULL, NULL, 'high'),
  ('@DMRussini', 'Dianna Russini', 'insider', NULL, NULL, 'high'),
  ('@JonHeyman', 'Jon Heyman', 'insider', NULL, NULL, 'high'),
  ('@BNightengale', 'Bob Nightengale', 'insider', NULL, NULL, 'high'),
  ('@Joelsherman1', 'Joel Sherman', 'insider', NULL, NULL, 'high'),
  ('@JesseRogersESPN', 'Jesse Rogers', 'insider', NULL, NULL, 'high'),
  ('@FriedgeHNIC', 'Elliotte Friedman', 'insider', NULL, NULL, 'high'),
  ('@PierreVLeBrun', 'Pierre LeBrun', 'insider', NULL, NULL, 'high'),
  ('@frank_seravalli', 'Frank Seravalli', 'insider', NULL, NULL, 'high'),
  ('@KevinWeekes', 'Kevin Weekes', 'insider', NULL, NULL, 'high'),
  ('@NicoleAuerbach', 'Nicole Auerbach', 'insider', NULL, NULL, 'high'),
  ('@Andy_Staples', 'Andy Staples', 'insider', NULL, NULL, 'high'),
  ('@slmandel', 'Stewart Mandel', 'insider', NULL, NULL, 'high'),
  ('@RossDellenger', 'Ross Dellenger', 'insider', NULL, NULL, 'high'),
  ('@FabrizioRomano', 'Fabrizio Romano', 'insider', NULL, NULL, 'high'),
  ('@arielhelwani', 'Ariel Helwani', 'insider', NULL, NULL, 'high'),
  ('@IanBegley', 'Ian Begley', 'beat_reporter', 'NBA', 'New York Knicks', 'high'),
  ('@FredKatz', 'Fred Katz', 'beat_reporter', 'NBA', 'New York Knicks', 'high'),
  ('@NYPost_Lewis', 'Brian Lewis', 'beat_reporter', 'NBA', 'Brooklyn Nets', 'high'),
  ('@erikslater_', 'Erik Slater', 'beat_reporter', 'NBA', 'Brooklyn Nets', 'high'),
  ('@AdamHimmelsbach', 'Adam Himmelsbach', 'beat_reporter', 'NBA', 'Boston Celtics', 'high'),
  ('@GwashburnGlobe', 'Gary Washburn', 'beat_reporter', 'NBA', 'Boston Celtics', 'high'),
  ('@KyleNeubeck', 'Kyle Neubeck', 'beat_reporter', 'NBA', 'Philadelphia 76ers', 'high'),
  ('@DerekBodnerNBA', 'Derek Bodner', 'beat_reporter', 'NBA', 'Philadelphia 76ers', 'high'),
  ('@mcten', 'Dave McMenamin', 'beat_reporter', 'NBA', 'Los Angeles Lakers', 'high'),
  ('@jovanbuha', 'Jovan Buha', 'beat_reporter', 'NBA', 'Los Angeles Lakers', 'high'),
  ('@anthonyVslater', 'Anthony Slater', 'beat_reporter', 'NBA', 'Golden State Warriors', 'high'),
  ('@ThompsonScribe', 'Marcus Thompson', 'beat_reporter', 'NBA', 'Golden State Warriors', 'high'),
  ('@IraHeatBeat', 'Ira Winderman', 'beat_reporter', 'NBA', 'Miami Heat', 'high'),
  ('@flasportsbuzz', 'Barry Jackson', 'beat_reporter', 'NBA', 'Miami Heat', 'high'),
  ('@espn_macmahon', 'Tim MacMahon', 'beat_reporter', 'NBA', 'Dallas Mavericks', 'high'),
  ('@townbrad', 'Brad Townsend', 'beat_reporter', 'NBA', 'Dallas Mavericks', 'high'),
  ('@KCJHoop', 'K.C. Johnson', 'beat_reporter', 'NBA', 'Chicago Bulls', 'high'),
  ('@JCowleyHoops', 'Joe Cowley', 'beat_reporter', 'NBA', 'Chicago Bulls', 'high'),
  ('@eric_nehm', 'Eric Nehm', 'beat_reporter', 'NBA', 'Milwaukee Bucks', 'high'),
  ('@JimOwczarski', 'Jim Owczarski', 'beat_reporter', 'NBA', 'Milwaukee Bucks', 'high'),
  ('@JordanRaanan', 'Jordan Raanan', 'beat_reporter', 'NFL', 'New York Giants', 'high'),
  ('@DDuggan21', 'Dan Duggan', 'beat_reporter', 'NFL', 'New York Giants', 'high'),
  ('@RichCimini', 'Rich Cimini', 'beat_reporter', 'NFL', 'New York Jets', 'high'),
  ('@ZackBlatt', 'Zack Rosenblatt', 'beat_reporter', 'NFL', 'New York Jets', 'high'),
  ('@jonmachota', 'Jon Machota', 'beat_reporter', 'NFL', 'Dallas Cowboys', 'high'),
  ('@toddarcher', 'Todd Archer', 'beat_reporter', 'NFL', 'Dallas Cowboys', 'high'),
  ('@Jeff_McLane', 'Jeff McLane', 'beat_reporter', 'NFL', 'Philadelphia Eagles', 'high'),
  ('@ZBerm', 'Zach Berman', 'beat_reporter', 'NFL', 'Philadelphia Eagles', 'high'),
  ('@ByNateTaylor', 'Nate Taylor', 'beat_reporter', 'NFL', 'Kansas City Chiefs', 'high'),
  ('@adamteicher', 'Adam Teicher', 'beat_reporter', 'NFL', 'Kansas City Chiefs', 'high'),
  ('@MaioccoNBCS', 'Matt Maiocco', 'beat_reporter', 'NFL', 'San Francisco 49ers', 'high'),
  ('@LombardiHimself', 'David Lombardi', 'beat_reporter', 'NFL', 'San Francisco 49ers', 'high'),
  ('@SalSports', 'Sal Capaccio', 'beat_reporter', 'NFL', 'Buffalo Bills', 'high'),
  ('@MattParrino', 'Matt Parrino', 'beat_reporter', 'NFL', 'Buffalo Bills', 'high'),
  ('@CameronWolfe', 'Cameron Wolfe', 'beat_reporter', 'NFL', 'Miami Dolphins', 'high'),
  ('@mattschneidman', 'Matt Schneidman', 'beat_reporter', 'NFL', 'Green Bay Packers', 'high'),
  ('@RobDemovsky', 'Rob Demovsky', 'beat_reporter', 'NFL', 'Green Bay Packers', 'high'),
  ('@adamjahns', 'Adam Jahns', 'beat_reporter', 'NFL', 'Chicago Bears', 'high'),
  ('@NicholasMoreano', 'Nicholas Moreano', 'beat_reporter', 'NFL', 'Chicago Bears', 'high'),
  ('@BryanHoch', 'Bryan Hoch', 'beat_reporter', 'MLB', 'New York Yankees', 'high'),
  ('@BrendanKutyNJ', 'Brendan Kuty', 'beat_reporter', 'MLB', 'New York Yankees', 'high'),
  ('@AnthonyDiComo', 'Anthony DiComo', 'beat_reporter', 'MLB', 'New York Mets', 'high'),
  ('@timbhealey', 'Tim Healey', 'beat_reporter', 'MLB', 'New York Mets', 'high'),
  ('@ChrisCotillo', 'Chris Cotillo', 'beat_reporter', 'MLB', 'Boston Red Sox', 'high'),
  ('@alexspeier', 'Alex Speier', 'beat_reporter', 'MLB', 'Boston Red Sox', 'high'),
  ('@Jack_A_Harris', 'Jack Harris', 'beat_reporter', 'MLB', 'Los Angeles Dodgers', 'high'),
  ('@FabianArdaya', 'Fabian Ardaya', 'beat_reporter', 'MLB', 'Los Angeles Dodgers', 'high'),
  ('@sahadevsharma', 'Sahadev Sharma', 'beat_reporter', 'MLB', 'Chicago Cubs', 'high'),
  ('@MLBastian', 'Jordan Bastian', 'beat_reporter', 'MLB', 'Chicago Cubs', 'high'),
  ('@DOBrienATL', 'David O’Brien', 'beat_reporter', 'MLB', 'Atlanta Braves', 'high'),
  ('@JustinCToscano', 'Justin Toscano', 'beat_reporter', 'MLB', 'Atlanta Braves', 'high'),
  ('@Chandler_Rome', 'Chandler Rome', 'beat_reporter', 'MLB', 'Houston Astros', 'high'),
  ('@brianmctaggart', 'Brian McTaggart', 'beat_reporter', 'MLB', 'Houston Astros', 'high'),
  ('@MattGelb', 'Matt Gelb', 'beat_reporter', 'MLB', 'Philadelphia Phillies', 'high'),
  ('@ToddZolecki', 'Todd Zolecki', 'beat_reporter', 'MLB', 'Philadelphia Phillies', 'high'),
  ('@sdutKevinAcee', 'Kevin Acee', 'beat_reporter', 'MLB', 'San Diego Padres', 'high'),
  ('@dennistlin', 'Dennis Lin', 'beat_reporter', 'MLB', 'San Diego Padres', 'high'),
  ('@Evan_P_Grant', 'Evan Grant', 'beat_reporter', 'MLB', 'Texas Rangers', 'high'),
  ('@JaredSandler', 'Jared Sandler', 'beat_reporter', 'MLB', 'Texas Rangers', 'high'),
  ('@vzmercogliano', 'Vince Mercogliano', 'beat_reporter', 'NHL', 'New York Rangers', 'high'),
  ('@NYP_Brooksie', 'Larry Brooks', 'beat_reporter', 'NHL', 'New York Rangers', 'high'),
  ('@StapeAthletic', 'Arthur Staple', 'beat_reporter', 'NHL', 'New York Islanders', 'high'),
  ('@AGrossNewsday', 'Andrew Gross', 'beat_reporter', 'NHL', 'New York Islanders', 'high'),
  ('@FlutoShinzawa', 'Fluto Shinzawa', 'beat_reporter', 'NHL', 'Boston Bruins', 'high'),
  ('@ConorRyan_93', 'Conor Ryan', 'beat_reporter', 'NHL', 'Boston Bruins', 'high'),
  ('@jonassiegel', 'Jonas Siegel', 'beat_reporter', 'NHL', 'Toronto Maple Leafs', 'high'),
  ('@markhmasters', 'Mark Masters', 'beat_reporter', 'NHL', 'Toronto Maple Leafs', 'high'),
  ('@JoeSmithNHL', 'Joe Smith', 'beat_reporter', 'NHL', 'Tampa Bay Lightning', 'high'),
  ('@EddieInTheYard', 'Eduardo Encina', 'beat_reporter', 'NHL', 'Tampa Bay Lightning', 'high'),
  ('@BenPopeCST', 'Ben Pope', 'beat_reporter', 'NHL', 'Chicago Blackhawks', 'high'),
  ('@ByScottPowers', 'Scott Powers', 'beat_reporter', 'NHL', 'Chicago Blackhawks', 'high'),
  ('@DooleyLAK', 'Zach Dooley', 'beat_reporter', 'NHL', 'Los Angeles Kings', 'high'),
  ('@mayorNHL', 'John Hoven', 'beat_reporter', 'NHL', 'Los Angeles Kings', 'high'),
  ('@Peter_Baugh', 'Peter Baugh', 'beat_reporter', 'NHL', 'Colorado Avalanche', 'high'),
  ('@evanrawal', 'Evan Rawal', 'beat_reporter', 'NHL', 'Colorado Avalanche', 'high'),
  ('@AZCardinals', 'Arizona Cardinals', 'team_official', 'NFL', 'Arizona Cardinals', 'medium'),
  ('@AtlantaFalcons', 'Atlanta Falcons', 'team_official', 'NFL', 'Atlanta Falcons', 'medium'),
  ('@Ravens', 'Baltimore Ravens', 'team_official', 'NFL', 'Baltimore Ravens', 'medium'),
  ('@BuffaloBills', 'Buffalo Bills', 'team_official', 'NFL', 'Buffalo Bills', 'medium'),
  ('@Panthers', 'Carolina Panthers', 'team_official', 'NFL', 'Carolina Panthers', 'medium'),
  ('@ChicagoBears', 'Chicago Bears', 'team_official', 'NFL', 'Chicago Bears', 'medium'),
  ('@Bengals', 'Cincinnati Bengals', 'team_official', 'NFL', 'Cincinnati Bengals', 'medium'),
  ('@Browns', 'Cleveland Browns', 'team_official', 'NFL', 'Cleveland Browns', 'medium'),
  ('@dallascowboys', 'Dallas Cowboys', 'team_official', 'NFL', 'Dallas Cowboys', 'medium'),
  ('@Broncos', 'Denver Broncos', 'team_official', 'NFL', 'Denver Broncos', 'medium'),
  ('@Lions', 'Detroit Lions', 'team_official', 'NFL', 'Detroit Lions', 'medium'),
  ('@packers', 'Green Bay Packers', 'team_official', 'NFL', 'Green Bay Packers', 'medium'),
  ('@HoustonTexans', 'Houston Texans', 'team_official', 'NFL', 'Houston Texans', 'medium'),
  ('@Colts', 'Indianapolis Colts', 'team_official', 'NFL', 'Indianapolis Colts', 'medium'),
  ('@Jaguars', 'Jacksonville Jaguars', 'team_official', 'NFL', 'Jacksonville Jaguars', 'medium'),
  ('@Chiefs', 'Kansas City Chiefs', 'team_official', 'NFL', 'Kansas City Chiefs', 'medium'),
  ('@Raiders', 'Las Vegas Raiders', 'team_official', 'NFL', 'Las Vegas Raiders', 'medium'),
  ('@chargers', 'Los Angeles Chargers', 'team_official', 'NFL', 'Los Angeles Chargers', 'medium'),
  ('@RamsNFL', 'Los Angeles Rams', 'team_official', 'NFL', 'Los Angeles Rams', 'medium'),
  ('@MiamiDolphins', 'Miami Dolphins', 'team_official', 'NFL', 'Miami Dolphins', 'medium'),
  ('@Vikings', 'Minnesota Vikings', 'team_official', 'NFL', 'Minnesota Vikings', 'medium'),
  ('@Patriots', 'New England Patriots', 'team_official', 'NFL', 'New England Patriots', 'medium'),
  ('@Saints', 'New Orleans Saints', 'team_official', 'NFL', 'New Orleans Saints', 'medium'),
  ('@Giants', 'New York Giants', 'team_official', 'NFL', 'New York Giants', 'medium'),
  ('@nyjets', 'New York Jets', 'team_official', 'NFL', 'New York Jets', 'medium'),
  ('@Eagles', 'Philadelphia Eagles', 'team_official', 'NFL', 'Philadelphia Eagles', 'medium'),
  ('@steelers', 'Pittsburgh Steelers', 'team_official', 'NFL', 'Pittsburgh Steelers', 'medium'),
  ('@49ers', 'San Francisco 49ers', 'team_official', 'NFL', 'San Francisco 49ers', 'medium'),
  ('@Seahawks', 'Seattle Seahawks', 'team_official', 'NFL', 'Seattle Seahawks', 'medium'),
  ('@Buccaneers', 'Tampa Bay Buccaneers', 'team_official', 'NFL', 'Tampa Bay Buccaneers', 'medium'),
  ('@Titans', 'Tennessee Titans', 'team_official', 'NFL', 'Tennessee Titans', 'medium'),
  ('@Commanders', 'Washington Commanders', 'team_official', 'NFL', 'Washington Commanders', 'medium'),
  ('@ATLHawks', 'Atlanta Hawks', 'team_official', 'NBA', 'Atlanta Hawks', 'medium'),
  ('@celtics', 'Boston Celtics', 'team_official', 'NBA', 'Boston Celtics', 'medium'),
  ('@BrooklynNets', 'Brooklyn Nets', 'team_official', 'NBA', 'Brooklyn Nets', 'medium'),
  ('@hornets', 'Charlotte Hornets', 'team_official', 'NBA', 'Charlotte Hornets', 'medium'),
  ('@chicagobulls', 'Chicago Bulls', 'team_official', 'NBA', 'Chicago Bulls', 'medium'),
  ('@cavs', 'Cleveland Cavaliers', 'team_official', 'NBA', 'Cleveland Cavaliers', 'medium'),
  ('@dallasmavs', 'Dallas Mavericks', 'team_official', 'NBA', 'Dallas Mavericks', 'medium'),
  ('@nuggets', 'Denver Nuggets', 'team_official', 'NBA', 'Denver Nuggets', 'medium'),
  ('@DetroitPistons', 'Detroit Pistons', 'team_official', 'NBA', 'Detroit Pistons', 'medium'),
  ('@warriors', 'Golden State Warriors', 'team_official', 'NBA', 'Golden State Warriors', 'medium'),
  ('@HoustonRockets', 'Houston Rockets', 'team_official', 'NBA', 'Houston Rockets', 'medium'),
  ('@Pacers', 'Indiana Pacers', 'team_official', 'NBA', 'Indiana Pacers', 'medium'),
  ('@LAClippers', 'Los Angeles Clippers', 'team_official', 'NBA', 'Los Angeles Clippers', 'medium'),
  ('@Lakers', 'Los Angeles Lakers', 'team_official', 'NBA', 'Los Angeles Lakers', 'medium'),
  ('@memgrizz', 'Memphis Grizzlies', 'team_official', 'NBA', 'Memphis Grizzlies', 'medium'),
  ('@MiamiHEAT', 'Miami Heat', 'team_official', 'NBA', 'Miami Heat', 'medium'),
  ('@Bucks', 'Milwaukee Bucks', 'team_official', 'NBA', 'Milwaukee Bucks', 'medium'),
  ('@Timberwolves', 'Minnesota Timberwolves', 'team_official', 'NBA', 'Minnesota Timberwolves', 'medium'),
  ('@PelicansNBA', 'New Orleans Pelicans', 'team_official', 'NBA', 'New Orleans Pelicans', 'medium'),
  ('@nyknicks', 'New York Knicks', 'team_official', 'NBA', 'New York Knicks', 'medium'),
  ('@okcthunder', 'Oklahoma City Thunder', 'team_official', 'NBA', 'Oklahoma City Thunder', 'medium'),
  ('@OrlandoMagic', 'Orlando Magic', 'team_official', 'NBA', 'Orlando Magic', 'medium'),
  ('@sixers', 'Philadelphia 76ers', 'team_official', 'NBA', 'Philadelphia 76ers', 'medium'),
  ('@Suns', 'Phoenix Suns', 'team_official', 'NBA', 'Phoenix Suns', 'medium'),
  ('@trailblazers', 'Portland Trail Blazers', 'team_official', 'NBA', 'Portland Trail Blazers', 'medium'),
  ('@SacramentoKings', 'Sacramento Kings', 'team_official', 'NBA', 'Sacramento Kings', 'medium'),
  ('@spurs', 'San Antonio Spurs', 'team_official', 'NBA', 'San Antonio Spurs', 'medium'),
  ('@Raptors', 'Toronto Raptors', 'team_official', 'NBA', 'Toronto Raptors', 'medium'),
  ('@utahjazz', 'Utah Jazz', 'team_official', 'NBA', 'Utah Jazz', 'medium'),
  ('@WashWizards', 'Washington Wizards', 'team_official', 'NBA', 'Washington Wizards', 'medium'),
  ('@Dbacks', 'Arizona Diamondbacks', 'team_official', 'MLB', 'Arizona Diamondbacks', 'medium'),
  ('@Braves', 'Atlanta Braves', 'team_official', 'MLB', 'Atlanta Braves', 'medium'),
  ('@Orioles', 'Baltimore Orioles', 'team_official', 'MLB', 'Baltimore Orioles', 'medium'),
  ('@RedSox', 'Boston Red Sox', 'team_official', 'MLB', 'Boston Red Sox', 'medium'),
  ('@Cubs', 'Chicago Cubs', 'team_official', 'MLB', 'Chicago Cubs', 'medium'),
  ('@whitesox', 'Chicago White Sox', 'team_official', 'MLB', 'Chicago White Sox', 'medium'),
  ('@Reds', 'Cincinnati Reds', 'team_official', 'MLB', 'Cincinnati Reds', 'medium'),
  ('@CleGuardians', 'Cleveland Guardians', 'team_official', 'MLB', 'Cleveland Guardians', 'medium'),
  ('@Rockies', 'Colorado Rockies', 'team_official', 'MLB', 'Colorado Rockies', 'medium'),
  ('@tigers', 'Detroit Tigers', 'team_official', 'MLB', 'Detroit Tigers', 'medium'),
  ('@astros', 'Houston Astros', 'team_official', 'MLB', 'Houston Astros', 'medium'),
  ('@Royals', 'Kansas City Royals', 'team_official', 'MLB', 'Kansas City Royals', 'medium'),
  ('@Angels', 'Los Angeles Angels', 'team_official', 'MLB', 'Los Angeles Angels', 'medium'),
  ('@Dodgers', 'Los Angeles Dodgers', 'team_official', 'MLB', 'Los Angeles Dodgers', 'medium'),
  ('@Marlins', 'Miami Marlins', 'team_official', 'MLB', 'Miami Marlins', 'medium'),
  ('@Brewers', 'Milwaukee Brewers', 'team_official', 'MLB', 'Milwaukee Brewers', 'medium'),
  ('@Twins', 'Minnesota Twins', 'team_official', 'MLB', 'Minnesota Twins', 'medium'),
  ('@Mets', 'New York Mets', 'team_official', 'MLB', 'New York Mets', 'medium'),
  ('@Yankees', 'New York Yankees', 'team_official', 'MLB', 'New York Yankees', 'medium'),
  ('@Athletics', 'Oakland Athletics', 'team_official', 'MLB', 'Oakland Athletics', 'medium'),
  ('@Phillies', 'Philadelphia Phillies', 'team_official', 'MLB', 'Philadelphia Phillies', 'medium'),
  ('@Pirates', 'Pittsburgh Pirates', 'team_official', 'MLB', 'Pittsburgh Pirates', 'medium'),
  ('@Padres', 'San Diego Padres', 'team_official', 'MLB', 'San Diego Padres', 'medium'),
  ('@SFGiants', 'San Francisco Giants', 'team_official', 'MLB', 'San Francisco Giants', 'medium'),
  ('@Mariners', 'Seattle Mariners', 'team_official', 'MLB', 'Seattle Mariners', 'medium'),
  ('@Cardinals', 'St. Louis Cardinals', 'team_official', 'MLB', 'St. Louis Cardinals', 'medium'),
  ('@RaysBaseball', 'Tampa Bay Rays', 'team_official', 'MLB', 'Tampa Bay Rays', 'medium'),
  ('@Rangers', 'Texas Rangers', 'team_official', 'MLB', 'Texas Rangers', 'medium'),
  ('@BlueJays', 'Toronto Blue Jays', 'team_official', 'MLB', 'Toronto Blue Jays', 'medium'),
  ('@Nationals', 'Washington Nationals', 'team_official', 'MLB', 'Washington Nationals', 'medium'),
  ('@AnaheimDucks', 'Anaheim Ducks', 'team_official', 'NHL', 'Anaheim Ducks', 'medium'),
  ('@ArizonaCoyotes', 'Arizona Coyotes', 'team_official', 'NHL', 'Arizona Coyotes', 'medium'),
  ('@NHLBruins', 'Boston Bruins', 'team_official', 'NHL', 'Boston Bruins', 'medium'),
  ('@BuffaloSabres', 'Buffalo Sabres', 'team_official', 'NHL', 'Buffalo Sabres', 'medium'),
  ('@NHLFlames', 'Calgary Flames', 'team_official', 'NHL', 'Calgary Flames', 'medium'),
  ('@Canes', 'Carolina Hurricanes', 'team_official', 'NHL', 'Carolina Hurricanes', 'medium'),
  ('@NHLBlackhawks', 'Chicago Blackhawks', 'team_official', 'NHL', 'Chicago Blackhawks', 'medium'),
  ('@Avalanche', 'Colorado Avalanche', 'team_official', 'NHL', 'Colorado Avalanche', 'medium'),
  ('@BlueJacketsNHL', 'Columbus Blue Jackets', 'team_official', 'NHL', 'Columbus Blue Jackets', 'medium'),
  ('@DallasStars', 'Dallas Stars', 'team_official', 'NHL', 'Dallas Stars', 'medium'),
  ('@DetroitRedWings', 'Detroit Red Wings', 'team_official', 'NHL', 'Detroit Red Wings', 'medium'),
  ('@EdmontonOilers', 'Edmonton Oilers', 'team_official', 'NHL', 'Edmonton Oilers', 'medium'),
  ('@FlaPanthers', 'Florida Panthers', 'team_official', 'NHL', 'Florida Panthers', 'medium'),
  ('@LAKings', 'Los Angeles Kings', 'team_official', 'NHL', 'Los Angeles Kings', 'medium'),
  ('@mnwild', 'Minnesota Wild', 'team_official', 'NHL', 'Minnesota Wild', 'medium'),
  ('@CanadiensMTL', 'Montreal Canadiens', 'team_official', 'NHL', 'Montreal Canadiens', 'medium'),
  ('@PredsNHL', 'Nashville Predators', 'team_official', 'NHL', 'Nashville Predators', 'medium'),
  ('@NJDevils', 'New Jersey Devils', 'team_official', 'NHL', 'New Jersey Devils', 'medium'),
  ('@NYIslanders', 'New York Islanders', 'team_official', 'NHL', 'New York Islanders', 'medium'),
  ('@NYRangers', 'New York Rangers', 'team_official', 'NHL', 'New York Rangers', 'medium'),
  ('@Senators', 'Ottawa Senators', 'team_official', 'NHL', 'Ottawa Senators', 'medium'),
  ('@NHLFlyers', 'Philadelphia Flyers', 'team_official', 'NHL', 'Philadelphia Flyers', 'medium'),
  ('@penguins', 'Pittsburgh Penguins', 'team_official', 'NHL', 'Pittsburgh Penguins', 'medium'),
  ('@SanJoseSharks', 'San Jose Sharks', 'team_official', 'NHL', 'San Jose Sharks', 'medium'),
  ('@SeattleKraken', 'Seattle Kraken', 'team_official', 'NHL', 'Seattle Kraken', 'medium'),
  ('@StLouisBlues', 'St. Louis Blues', 'team_official', 'NHL', 'St. Louis Blues', 'medium'),
  ('@TBLightning', 'Tampa Bay Lightning', 'team_official', 'NHL', 'Tampa Bay Lightning', 'medium'),
  ('@MapleLeafs', 'Toronto Maple Leafs', 'team_official', 'NHL', 'Toronto Maple Leafs', 'medium'),
  ('@Canucks', 'Vancouver Canucks', 'team_official', 'NHL', 'Vancouver Canucks', 'medium'),
  ('@GoldenKnights', 'Vegas Golden Knights', 'team_official', 'NHL', 'Vegas Golden Knights', 'medium'),
  ('@Capitals', 'Washington Capitals', 'team_official', 'NHL', 'Washington Capitals', 'medium'),
  ('@NHLJets', 'Winnipeg Jets', 'team_official', 'NHL', 'Winnipeg Jets', 'medium'),
  ('@NFL', 'NFL', 'league_official', 'NFL', NULL, 'medium'),
  ('@nflnetwork', 'NFL Network', 'league_official', 'NFL Network', NULL, 'medium'),
  ('@NFL345', 'NFL Communications', 'league_official', 'NFL Communications', NULL, 'medium'),
  ('@NBA', 'NBA', 'league_official', 'NBA', NULL, 'medium'),
  ('@NBAPR', 'NBA Communications', 'league_official', 'NBA Communications', NULL, 'medium'),
  ('@NBATV', 'NBA TV', 'league_official', 'NBA TV', NULL, 'medium'),
  ('@MLB', 'MLB', 'league_official', 'MLB', NULL, 'medium'),
  ('@MLB_PR', 'MLB Communications', 'league_official', 'MLB Communications', NULL, 'medium'),
  ('@MLBNetwork', 'MLB Network', 'league_official', 'MLB Network', NULL, 'medium'),
  ('@NHL', 'NHL', 'league_official', 'NHL', NULL, 'medium'),
  ('@PR_NHL', 'NHL Public Relations', 'league_official', 'NHL Public Relations', NULL, 'medium'),
  ('@NHLNetwork', 'NHL Network', 'league_official', 'NHL Network', NULL, 'medium'),
  ('@NCAA', 'NCAA', 'league_official', 'NCAA', NULL, 'medium'),
  ('@NCAAFootball', 'NCAA Football', 'league_official', 'NCAA Football', NULL, 'medium'),
  ('@MarchMadnessMBB', 'NCAA March Madness', 'league_official', 'NCAA March Madness', NULL, 'medium'),
  ('@MLS', 'Major League Soccer', 'league_official', 'Major League Soccer', NULL, 'medium'),
  ('@premierleague', 'Premier League', 'league_official', 'Premier League', NULL, 'medium'),
  ('@LaLiga', 'La Liga', 'league_official', 'La Liga', NULL, 'medium'),
  ('@ufc', 'UFC', 'league_official', 'UFC', NULL, 'medium'),
  ('@WWE', 'WWE', 'league_official', 'WWE', NULL, 'medium'),
  ('@PGATOUR', 'PGA Tour', 'league_official', 'PGA Tour', NULL, 'medium'),
  ('@livgolf_league', 'LIV Golf', 'league_official', 'LIV Golf', NULL, 'medium'),
  ('@atptour', 'ATP Tour', 'league_official', 'ATP Tour', NULL, 'medium'),
  ('@WTA', 'WTA', 'league_official', 'WTA', NULL, 'medium'),
  ('@F1', 'Formula 1', 'league_official', 'Formula 1', NULL, 'medium'),
  ('@NASCAR', 'NASCAR', 'league_official', 'NASCAR', NULL, 'medium'),
  ('@IndyCar', 'IndyCar', 'league_official', 'IndyCar', NULL, 'medium'),
  ('@Olympics', 'Olympics', 'league_official', 'Olympics', NULL, 'medium'),
  ('@FIFAcom', 'FIFA', 'league_official', 'FIFA', NULL, 'medium'),
  ('@UEFA', 'UEFA', 'league_official', 'UEFA', NULL, 'medium'),
  ('@BroadwayLeague', 'The Broadway League', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@playbill', 'Playbill', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@BroadwayWorld', 'BroadwayWorld', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@Broadwaycom', 'Broadway.com', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@TodayTix', 'TodayTix', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@TheaterMania', 'TheaterMania', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@NYTheatreGuide', 'New York Theatre Guide', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@LCTheater', 'Lincoln Center Theater', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@roundaboutnyc', 'Roundabout Theatre Company', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@MTC_NYC', 'Manhattan Theatre Club', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@2STNYC', 'Second Stage Theater', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@NYCityCenter', 'New York City Center', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@PublicTheaterNY', 'The Public Theater', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@AtlanticTheater', 'Atlantic Theater Company', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@StAnnsWarehouse', 'St. Ann’s Warehouse', 'broadway_org', 'Broadway', NULL, 'medium'),
  ('@ShubertTheatre', 'Shubert Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@GershwinTheatre', 'Gershwin Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@MajesticBroadway', 'Majestic Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@MinskoffTheatre', 'Minskoff Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@LyricBroadway', 'Lyric Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@NewAmsterdam', 'New Amsterdam Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@StJamesTheatre', 'St. James Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@WinterGardenNYC', 'Winter Garden Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@PalaceTheatreNY', 'Palace Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@BroadhurstThtr', 'Broadhurst Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@ImperialBroadway', 'Imperial Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@HirschfeldBroadway', 'Al Hirschfeld Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@LongacreTheatre', 'Longacre Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@MusicBoxNYC', 'Music Box Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@WalterKerrBway', 'Walter Kerr Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@BelascoTheatre', 'Belasco Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@FriedmanTheatre', 'Friedman Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@BoothTheatreNY', 'Booth Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@BarrymoreBway', 'Ethel Barrymore Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@TheLionKing', 'The Lion King', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@HamiltonMusical', 'Hamilton', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@WICKED_Musical', 'Wicked', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@BookofMormon', 'The Book of Mormon', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@ChicagoMusical', 'Chicago', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@MoulinRougeBway', 'Moulin Rouge! The Musical', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@hadestown', 'Hadestown', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@sixthemusical', 'Six The Musical', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@CursedChildNYC', 'Harry Potter and the Cursed Child', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@Aladdin', 'Aladdin', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@MJtheMusical', 'MJ The Musical', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@AndJulietBway', '& Juliet', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@BTTFBway', 'Back to the Future The Musical', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@SpamalotBway', 'Spamalot', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@GatsbyMusical', 'The Great Gatsby Musical', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@HellsKitchenBway', 'Hell''s Kitchen Musical', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@NotebookBway', 'The Notebook Musical', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@WFElephantsBway', 'Water for Elephants', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@SweeneyToddBway', 'Sweeney Todd', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@SLIHmusical', 'Some Like It Hot', 'broadway_show', 'Broadway', NULL, 'medium'),
  ('@ScottRudin', 'Scott Rudin', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@jeffrey_seller', 'Jeffrey Seller', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@KevinMcCollum', 'Kevin McCollum', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@SoniaFriedman', 'Sonia Friedman', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@Jordan_Roth', 'Jordan Roth', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@DarylRoth', 'Daryl Roth', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@HunterArnold', 'Hunter Arnold', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@davidmstone', 'David Stone', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@kendavenport', 'Ken Davenport', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@MichaelPaulson', 'Michael Paulson', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@GordonCox', 'Gordon Cox', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@JesseKGreen', 'Jesse Green', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@RyanMcPhee', 'Ryan McPhee', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@AndrewGans', 'Andrew Gans', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@frankjrizzo', 'Frank Rizzo', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@mattwindman', 'Matt Windman', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@mrdavegordon', 'David Gordon', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@fdilella', 'Frank DiLella', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@ChrisJonesTrib', 'Chris Jones', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@BwayAcrossUSA', 'Broadway Across America', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@NationalTourNews', 'National Tour News', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BroadwayInChi', 'Broadway in Chicago', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BroadwaySF', 'BroadwaySF', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BroadwayLA', 'Broadway in Hollywood', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BOS_Broadway', 'Broadway in Boston', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BwayAtlanta', 'Broadway in Atlanta', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BwayDallas', 'Broadway in Dallas', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BroadwayDC', 'Broadway in DC', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@Mirvish', 'Broadway in Toronto', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@LiveNation', 'Live Nation', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@AEGPresents', 'AEG Presents', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@Ticketmaster', 'Ticketmaster', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@bowerypresents', 'Bowery Presents', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@goldenvoice', 'Goldenvoice', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@TheGarden', 'MSG Entertainment', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@C3Presents', 'C3 Presents', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@mammothlive', 'Mammoth Live', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@apeconcerts', 'Another Planet Entertainment', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@OutbackPresents', 'Outback Presents', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@eventim', 'Eventim', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@kililive', 'Kilimanjaro Live', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@SJMConcerts', 'SJM Concerts', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@barclayscenter', 'Barclays Center', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@RadioCity', 'Radio City Music Hall', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@RedRocksCO', 'Red Rocks Amphitheatre', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@HollywoodBowl', 'Hollywood Bowl', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@TheForum', 'The Forum LA', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@cryptocomarena', 'Crypto.com Arena', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@UnitedCenter', 'United Center', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@wembleystadium', 'Wembley Stadium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@TheO2', 'O2 Arena London', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@SoFiStadium', 'SoFi Stadium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@AllegiantStadm', 'Allegiant Stadium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@TMobileArena', 'T-Mobile Arena', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@MGMGrand', 'MGM Grand Garden Arena', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@BeaconTheatre', 'Beacon Theatre', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@theryman', 'Ryman Auditorium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@opry', 'Grand Ole Opry', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@GreekTheatreLA', 'The Greek Theatre LA', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@ForestHillsStdm', 'Forest Hills Stadium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@TheAnthemDC', 'The Anthem DC', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@taylorswift13', 'Taylor Swift', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@Drake', 'Drake', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@Beyonce', 'Beyoncé', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@theweeknd', 'The Weeknd', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@sanbenito', 'Bad Bunny', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@MorganWallen', 'Morgan Wallen', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@Harry_Styles', 'Harry Styles', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@edsheeran', 'Ed Sheeran', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@kendricklamar', 'Kendrick Lamar', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@sza', 'SZA', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@trvisXX', 'Travis Scott', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@PostMalone', 'Post Malone', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@billieeilish', 'Billie Eilish', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@ArianaGrande', 'Ariana Grande', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@BrunoMars', 'Bruno Mars', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@lukecombs', 'Luke Combs', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@zachlanebryan', 'Zach Bryan', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@oliviarodrigo', 'Olivia Rodrigo', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@DojaCat', 'Doja Cat', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@tylerthecreator', 'Tyler, The Creator', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@Metallica', 'Metallica', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@coldplay', 'Coldplay', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@RollingStones', 'The Rolling Stones', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@Springsteen', 'Bruce Springsteen', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@billyjoel', 'Billy Joel', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@phish', 'Phish', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@deadandcompany', 'Dead & Company', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@U2', 'U2', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@PearlJam', 'Pearl Jam', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@foofighters', 'Foo Fighters', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@thekillers', 'The Killers', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@GreenDay', 'Green Day', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@blink182', 'Blink-182', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@ChiliPeppers', 'Red Hot Chili Peppers', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@Imaginedragons', 'Imagine Dragons', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@LanaDelRey', 'Lana Del Rey', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@the1975', 'The 1975', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@paramore', 'Paramore', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@fredagainagain1', 'Fred Again', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@odesza', 'Odesza', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@Pollstar', 'Pollstar', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@billboard', 'Billboard Touring', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@Variety', 'Variety Music', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@RollingStone', 'Rolling Stone Music', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@livenation', 'Live Music Industry', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@musicbizworld', 'Music Business Worldwide', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@HITSDD', 'HITS Daily Double', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@consequence', 'Consequence', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@brooklynvegan', 'Brooklyn Vegan', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@pitchfork', 'Pitchfork', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@NME', 'NME', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@ComplexMusic', 'Complex Music', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@thefader', 'The FADER', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@Loudwire', 'Loudwire', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@stereogum', 'Stereogum', 'concert_reporter', 'Concerts', NULL, 'medium')
ON CONFLICT (handle) DO NOTHING;

-- ============================================================================
-- (4b) Seed performer_subreddits (176 team-sub pairs across 7 leagues)
-- ============================================================================
-- Auto-seed subreddit map for 6 major sports + F1 (NBA, NFL, MLB, NHL, WNBA, MLS, F1)
INSERT INTO performer_subreddits(tevo_performer_id, subreddit, is_primary, notes)
SELECT pm.performer_id, t.sub, true, 'auto-seeded ' || t.league
FROM performer_metadata pm
JOIN (VALUES
  ('Atlanta Hawks', 'AtlantaHawks', 'NBA'),
  ('Boston Celtics', 'bostonceltics', 'NBA'),
  ('Brooklyn Nets', 'GoNets', 'NBA'),
  ('Charlotte Hornets', 'CharlotteHornets', 'NBA'),
  ('Chicago Bulls', 'chicagobulls', 'NBA'),
  ('Cleveland Cavaliers', 'clevelandcavs', 'NBA'),
  ('Dallas Mavericks', 'Mavericks', 'NBA'),
  ('Denver Nuggets', 'denvernuggets', 'NBA'),
  ('Detroit Pistons', 'DetroitPistons', 'NBA'),
  ('Golden State Warriors', 'warriors', 'NBA'),
  ('Houston Rockets', 'rockets', 'NBA'),
  ('Indiana Pacers', 'pacers', 'NBA'),
  ('Los Angeles Clippers', 'LAClippers', 'NBA'),
  ('Los Angeles Lakers', 'lakers', 'NBA'),
  ('Memphis Grizzlies', 'memphisgrizzlies', 'NBA'),
  ('Miami Heat', 'heat', 'NBA'),
  ('Milwaukee Bucks', 'MkeBucks', 'NBA'),
  ('Minnesota Timberwolves', 'timberwolves', 'NBA'),
  ('New Orleans Pelicans', 'NOLAPelicans', 'NBA'),
  ('New York Knicks', 'NYKnicks', 'NBA'),
  ('Oklahoma City Thunder', 'Thunder', 'NBA'),
  ('Orlando Magic', 'OrlandoMagic', 'NBA'),
  ('Philadelphia 76ers', 'sixers', 'NBA'),
  ('Phoenix Suns', 'suns', 'NBA'),
  ('Portland Trail Blazers', 'ripcity', 'NBA'),
  ('Sacramento Kings', 'kings', 'NBA'),
  ('San Antonio Spurs', 'NBASpurs', 'NBA'),
  ('Toronto Raptors', 'torontoraptors', 'NBA'),
  ('Utah Jazz', 'UtahJazz', 'NBA'),
  ('Washington Wizards', 'washingtonwizards', 'NBA'),
  ('Arizona Cardinals', 'AZCardinals', 'NFL'),
  ('Atlanta Falcons', 'falcons', 'NFL'),
  ('Baltimore Ravens', 'ravens', 'NFL'),
  ('Buffalo Bills', 'buffalobills', 'NFL'),
  ('Carolina Panthers', 'panthers', 'NFL'),
  ('Chicago Bears', 'CHIBears', 'NFL'),
  ('Cincinnati Bengals', 'bengals', 'NFL'),
  ('Cleveland Browns', 'Browns', 'NFL'),
  ('Dallas Cowboys', 'cowboys', 'NFL'),
  ('Denver Broncos', 'DenverBroncos', 'NFL'),
  ('Detroit Lions', 'detroitlions', 'NFL'),
  ('Green Bay Packers', 'GreenBayPackers', 'NFL'),
  ('Houston Texans', 'Texans', 'NFL'),
  ('Indianapolis Colts', 'Colts', 'NFL'),
  ('Jacksonville Jaguars', 'Jaguars', 'NFL'),
  ('Kansas City Chiefs', 'KansasCityChiefs', 'NFL'),
  ('Las Vegas Raiders', 'raiders', 'NFL'),
  ('Los Angeles Chargers', 'Chargers', 'NFL'),
  ('Los Angeles Rams', 'LosAngelesRams', 'NFL'),
  ('Miami Dolphins', 'miamidolphins', 'NFL'),
  ('Minnesota Vikings', 'minnesotavikings', 'NFL'),
  ('New England Patriots', 'Patriots', 'NFL'),
  ('New Orleans Saints', 'Saints', 'NFL'),
  ('New York Giants', 'NYGiants', 'NFL'),
  ('New York Jets', 'nyjets', 'NFL'),
  ('Philadelphia Eagles', 'eagles', 'NFL'),
  ('Pittsburgh Steelers', 'steelers', 'NFL'),
  ('San Francisco 49ers', '49ers', 'NFL'),
  ('Seattle Seahawks', 'Seahawks', 'NFL'),
  ('Tampa Bay Buccaneers', 'buccaneers', 'NFL'),
  ('Tennessee Titans', 'Tennesseetitans', 'NFL'),
  ('Washington Commanders', 'Commanders', 'NFL'),
  ('Arizona Diamondbacks', 'azdiamondbacks', 'MLB'),
  ('Atlanta Braves', 'Braves', 'MLB'),
  ('Baltimore Orioles', 'orioles', 'MLB'),
  ('Boston Red Sox', 'redsox', 'MLB'),
  ('Chicago Cubs', 'CHICubs', 'MLB'),
  ('Chicago White Sox', 'whitesox', 'MLB'),
  ('Cincinnati Reds', 'Reds', 'MLB'),
  ('Cleveland Guardians', 'clevelandguardians', 'MLB'),
  ('Colorado Rockies', 'ColoradoRockies', 'MLB'),
  ('Detroit Tigers', 'motorcitykitties', 'MLB'),
  ('Houston Astros', 'Astros', 'MLB'),
  ('Kansas City Royals', 'KCRoyals', 'MLB'),
  ('Los Angeles Angels', 'AngelsBaseball', 'MLB'),
  ('Los Angeles Dodgers', 'Dodgers', 'MLB'),
  ('Miami Marlins', 'letsgofish', 'MLB'),
  ('Milwaukee Brewers', 'Brewers', 'MLB'),
  ('Minnesota Twins', 'minnesotatwins', 'MLB'),
  ('New York Mets', 'NewYorkMets', 'MLB'),
  ('New York Yankees', 'NYYankees', 'MLB'),
  ('Oakland Athletics', 'OaklandAthletics', 'MLB'),
  ('Athletics', 'OaklandAthletics', 'MLB'),
  ('Philadelphia Phillies', 'phillies', 'MLB'),
  ('Pittsburgh Pirates', 'buccos', 'MLB'),
  ('San Diego Padres', 'Padres', 'MLB'),
  ('San Francisco Giants', 'SFGiants', 'MLB'),
  ('Seattle Mariners', 'Mariners', 'MLB'),
  ('St. Louis Cardinals', 'Cardinals', 'MLB'),
  ('Tampa Bay Rays', 'tampabayrays', 'MLB'),
  ('Texas Rangers', 'TexasRangers', 'MLB'),
  ('Toronto Blue Jays', 'Torontobluejays', 'MLB'),
  ('Washington Nationals', 'Nationals', 'MLB'),
  ('Anaheim Ducks', 'AnaheimDucks', 'NHL'),
  ('Arizona Coyotes', 'Coyotes', 'NHL'),
  ('Boston Bruins', 'BostonBruins', 'NHL'),
  ('Buffalo Sabres', 'sabres', 'NHL'),
  ('Calgary Flames', 'CalgaryFlames', 'NHL'),
  ('Carolina Hurricanes', 'canes', 'NHL'),
  ('Chicago Blackhawks', 'hawks', 'NHL'),
  ('Colorado Avalanche', 'ColoradoAvalanche', 'NHL'),
  ('Columbus Blue Jackets', 'BlueJackets', 'NHL'),
  ('Dallas Stars', 'DallasStars', 'NHL'),
  ('Detroit Red Wings', 'DetroitRedWings', 'NHL'),
  ('Edmonton Oilers', 'EdmontonOilers', 'NHL'),
  ('Florida Panthers', 'FloridaPanthers', 'NHL'),
  ('Los Angeles Kings', 'losangeleskings', 'NHL'),
  ('Minnesota Wild', 'wildhockey', 'NHL'),
  ('Montreal Canadiens', 'Habs', 'NHL'),
  ('Nashville Predators', 'Predators', 'NHL'),
  ('New Jersey Devils', 'devils', 'NHL'),
  ('New York Islanders', 'NewYorkIslanders', 'NHL'),
  ('New York Rangers', 'rangers', 'NHL'),
  ('Ottawa Senators', 'OttawaSenators', 'NHL'),
  ('Philadelphia Flyers', 'Flyers', 'NHL'),
  ('Pittsburgh Penguins', 'penguins', 'NHL'),
  ('San Jose Sharks', 'SanJoseSharks', 'NHL'),
  ('Seattle Kraken', 'SeattleKraken', 'NHL'),
  ('St. Louis Blues', 'stlouisblues', 'NHL'),
  ('Tampa Bay Lightning', 'TampaBayLightning', 'NHL'),
  ('Toronto Maple Leafs', 'leafs', 'NHL'),
  ('Vancouver Canucks', 'canucks', 'NHL'),
  ('Vegas Golden Knights', 'goldenknights', 'NHL'),
  ('Washington Capitals', 'caps', 'NHL'),
  ('Winnipeg Jets', 'winnipegjets', 'NHL'),
  ('New York Liberty', 'NewYorkLiberty', 'WNBA'),
  ('Las Vegas Aces', 'lvaces', 'WNBA'),
  ('Connecticut Sun', 'ConnecticutSun', 'WNBA'),
  ('Phoenix Mercury', 'PhoenixMercury', 'WNBA'),
  ('Minnesota Lynx', 'MinnesotaLynx', 'WNBA'),
  ('Seattle Storm', 'SeattleStorm', 'WNBA'),
  ('Chicago Sky', 'chicagosky', 'WNBA'),
  ('Indiana Fever', 'IndianaFever', 'WNBA'),
  ('Atlanta Dream', 'atlantadream', 'WNBA'),
  ('Dallas Wings', 'DallasWingsBB', 'WNBA'),
  ('Washington Mystics', 'WashingtonMystics', 'WNBA'),
  ('Los Angeles Sparks', 'LASparks', 'WNBA'),
  ('Inter Miami CF', 'InterMiamiCF', 'MLS'),
  ('Los Angeles FC', 'LAFC', 'MLS'),
  ('LA Galaxy', 'LAGalaxy', 'MLS'),
  ('Atlanta United', 'atlantaunited', 'MLS'),
  ('New York City FC', 'NYCFC', 'MLS'),
  ('New York Red Bulls', 'RBNY', 'MLS'),
  ('Seattle Sounders FC', 'SoundersFC', 'MLS'),
  ('Portland Timbers', 'timbers', 'MLS'),
  ('Toronto FC', 'tfc', 'MLS'),
  ('Philadelphia Union', 'PhillyUnion', 'MLS'),
  ('D.C. United', 'DCUnited', 'MLS'),
  ('New England Revolution', 'NERevolution', 'MLS'),
  ('Chicago Fire FC', 'ChicagoFire', 'MLS'),
  ('Columbus Crew', 'thecrew', 'MLS'),
  ('Houston Dynamo FC', 'Dynamo', 'MLS'),
  ('Sporting Kansas City', 'SportingKC', 'MLS'),
  ('FC Dallas', 'fcdallas', 'MLS'),
  ('Real Salt Lake', 'RSL', 'MLS'),
  ('Colorado Rapids', 'ColoradoRapids', 'MLS'),
  ('Minnesota United FC', 'MNUnited', 'MLS'),
  ('Nashville SC', 'NashvilleSC', 'MLS'),
  ('FC Cincinnati', 'FCCincinnati', 'MLS'),
  ('Austin FC', 'AustinFC', 'MLS'),
  ('St. Louis City SC', 'StLouisCitySC', 'MLS'),
  ('San Jose Earthquakes', 'quakes', 'MLS'),
  ('Charlotte FC', 'CharlotteFC', 'MLS'),
  ('Vancouver Whitecaps FC', 'Whitecaps', 'MLS'),
  ('CF Montreal', 'cfmontreal', 'MLS'),
  ('Orlando City SC', 'OrlandoCitySC', 'MLS'),
  ('Red Bull Racing', 'redbullracing', 'F1'),
  ('Mercedes-AMG Petronas F1 Team', 'MercedesAMGF1', 'F1'),
  ('Scuderia Ferrari', 'scuderiaferrari', 'F1'),
  ('McLaren F1 Team', 'McLarenF1', 'F1'),
  ('Aston Martin Aramco F1 Team', 'astonmartinf1', 'F1'),
  ('BWT Alpine F1 Team', 'AlpineF1Team', 'F1'),
  ('Williams Racing', 'WilliamsF1', 'F1'),
  ('MoneyGram Haas F1 Team', 'HaasF1Team', 'F1'),
  ('Stake F1 Team Kick Sauber', 'StakeF1', 'F1'),
  ('Visa Cash App RB F1 Team', 'VisaCashAppRB', 'F1')
) AS t(team_name, sub, league) ON pm.name = t.team_name
ON CONFLICT (tevo_performer_id, subreddit) DO NOTHING;

-- ============================================================================
-- (5) match_news_keywords — does this title/body trigger any keyword?
-- ============================================================================

CREATE OR REPLACE FUNCTION match_news_keywords(p_text text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  r RECORD; v_hits jsonb := '[]'::jsonb; v_categories jsonb := '{}'::jsonb;
  v_total_weight numeric := 0; v_matched boolean; v_pattern text;
BEGIN
  IF p_text IS NULL OR length(p_text) = 0 THEN
    RETURN jsonb_build_object('hits','[]'::jsonb,'categories','{}'::jsonb,'total_weight',0);
  END IF;
  FOR r IN SELECT keyword, category, weight FROM news_keywords LOOP
    -- Word-boundary regex; escape regex metas
    v_pattern := '\m' ||
      regexp_replace(r.keyword, '([.\\\-\(\)\[\]\?\*\+\^\$\|])', '\\\1', 'g')
      || '\M';
    -- Short all-uppercase tokens (IL, IR, LTIR) — case-sensitive (avoids "IL" inside "Phillies")
    IF length(r.keyword) <= 4 AND r.keyword = upper(r.keyword) AND r.keyword ~ '[A-Z]' THEN
      v_matched := p_text ~ v_pattern;
    ELSE
      v_matched := p_text ~* v_pattern;
    END IF;
    IF v_matched THEN
      v_hits := v_hits || to_jsonb(r.keyword);
      v_categories := v_categories ||
        jsonb_build_object(r.category,
          COALESCE((v_categories->>r.category)::numeric, 0) + r.weight);
      v_total_weight := v_total_weight + r.weight;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('hits', v_hits, 'categories', v_categories, 'total_weight', v_total_weight);
END; $$;

COMMENT ON FUNCTION match_news_keywords IS
  'Returns matched keywords + per-category weight totals for a given text. '
  'Used by v_reddit_important_recent and the future chatbot prompt builder.';

-- ============================================================================
-- (6) v_reddit_important_recent — Reddit posts in last 24h with keyword hits
-- ============================================================================

CREATE OR REPLACE VIEW v_reddit_important_recent AS
SELECT
  rp.reddit_post_id,
  rp.subreddit,
  rp.tevo_performer_id,
  rp.title,
  rp.author,
  rp.url,
  rp.created_utc,
  match_news_keywords(rp.title || ' ' || COALESCE(rp.body,'')) AS keyword_match
FROM reddit_posts rp
WHERE rp.created_utc > now() - interval '48 hours'
  AND (match_news_keywords(rp.title || ' ' || COALESCE(rp.body,''))->>'total_weight')::numeric > 0;

COMMENT ON VIEW v_reddit_important_recent IS
  '48h window of Reddit posts that hit at least one news_keywords entry. '
  'AI/RAG consumer reads this directly: title + url + matched keywords + '
  'category weights = ready-to-quote signal.';

-- ============================================================================
-- (7) Extend get_event_context — add important_news + known x-account count
-- ============================================================================

CREATE OR REPLACE FUNCTION get_event_context(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_event jsonb; v_pricing jsonb; v_espn jsonb; v_performer jsonb;
  v_weather jsonb; v_competitors jsonb; v_orders jsonb;
  v_odds jsonb; v_reddit jsonb;
  v_news jsonb; v_x jsonb;
BEGIN
  SELECT to_jsonb(e) - 'performer_ids' INTO v_event FROM events e WHERE id = p_event_id;
  IF v_event IS NULL THEN
    RETURN jsonb_build_object('error', 'event_not_found', 'tevo_event_id', p_event_id);
  END IF;
  SELECT to_jsonb(ef) INTO v_pricing FROM v_event_full_v2 ef WHERE ef.tevo_event_id = p_event_id;
  SELECT jsonb_build_object(
    'espn_event_id', x.espn_event_id,
    'latest_state',  (SELECT state FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1),
    'latest_status', (SELECT status_short FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1),
    'latest_score',  (SELECT home_score::text || '-' || away_score::text FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1)
  ) INTO v_espn FROM event_xref x WHERE x.tevo_event_id = p_event_id LIMIT 1;
  SELECT jsonb_build_object(
    'tevo_performer_id', pw.tevo_performer_id, 'wiki_title', pw.wiki_title,
    'wiki_url', pw.wiki_url, 'description', pw.description,
    'extract', pw.extract, 'image_url', pw.image_url
  ) INTO v_performer FROM performer_wikipedia pw
  JOIN events e ON e.primary_performer_id = pw.tevo_performer_id
  WHERE e.id = p_event_id AND NOT pw.is_rejected LIMIT 1;
  SELECT to_jsonb(w) INTO v_weather FROM v_event_weather_with_fallback w WHERE w.tevo_event_id = p_event_id;
  SELECT competitors INTO v_competitors FROM event_competitors_snapshot WHERE tevo_event_id = p_event_id;
  SELECT to_jsonb(o) INTO v_orders FROM our_orders_by_event o WHERE o.tevo_event_id = p_event_id;
  SELECT to_jsonb(bo) INTO v_odds FROM v_event_betting_odds_latest bo WHERE bo.tevo_event_id = p_event_id;
  SELECT to_jsonb(rp) INTO v_reddit
  FROM v_performer_reddit_pulse rp
  JOIN events e ON e.primary_performer_id = rp.tevo_performer_id
  WHERE e.id = p_event_id;

  -- NEW: important_news (Reddit posts with keyword hits, last 48h, on this performer's subs)
  SELECT jsonb_agg(jsonb_build_object(
           'title', vn.title,
           'subreddit', vn.subreddit,
           'created_utc', vn.created_utc,
           'url', vn.url,
           'matched', vn.keyword_match->'hits',
           'categories', vn.keyword_match->'categories'
         ) ORDER BY vn.created_utc DESC)
    INTO v_news
  FROM v_reddit_important_recent vn
  JOIN events e ON e.primary_performer_id = vn.tevo_performer_id
  WHERE e.id = p_event_id
  LIMIT 10;

  -- NEW: known X-account count for this event's primary performer name
  SELECT jsonb_build_object(
           'team_known', count(*) FILTER (WHERE account_type = 'team_official'),
           'beat_reporters_known', count(*) FILTER (WHERE account_type = 'beat_reporter'),
           'league_known', count(*) FILTER (WHERE account_type = 'league_official'),
           'insiders_total', (SELECT count(*) FROM important_x_accounts WHERE account_type = 'insider')
         )
    INTO v_x
  FROM important_x_accounts xa
  JOIN events e ON e.primary_performer_name = xa.team_name
  WHERE e.id = p_event_id;

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id, 'event', v_event,
    'pricing', COALESCE(v_pricing, '{}'::jsonb),
    'espn', COALESCE(v_espn, jsonb_build_object('present', false)),
    'odds', COALESCE(v_odds, jsonb_build_object('present', false)),
    'performer', COALESCE(v_performer, jsonb_build_object('present', false)),
    'weather', COALESCE(v_weather, jsonb_build_object('present', false)),
    'competitors', COALESCE(v_competitors, '[]'::jsonb),
    'reddit', COALESCE(v_reddit, jsonb_build_object('present', false)),
    'important_news', COALESCE(v_news, '[]'::jsonb),
    'x_accounts_known', COALESCE(v_x, jsonb_build_object('team_known', 0)),
    'our_orders', COALESCE(v_orders, jsonb_build_object('present', false)),
    'generated_at', now()
  );
END; $$;

COMMENT ON FUNCTION get_event_context IS
  'Single JSON bundle for AI/RAG consumers covering an event from every '
  'angle: basics, pricing, ESPN, odds, Wikipedia, weather, competitors, '
  'Reddit pulse, important_news (keyword-flagged Reddit posts), and known '
  'X-account roster counts. Schema-free interface for chatbot prompts.';
