-- Migration 20261116230000 · level:data-collection · lane:A1 (data plane — MLB schedule) · writes:mlb_ticket_team(+sport_id,league_name,parent_org_name; +120 clubs),mlb_ticket_game(+sport_id),mlb_ticket_direct_url(),mlb_ticket_fire(),mlb_ticket_tick(),mlb_ticket_match()(new signature),mlb_ticket_match_sg()(new signature),v_mlb_schedule_feed · reads:net._http_response,events,sg_events_canonical,aq_event_map · pre:20261116220000
--
-- Minor league games in the MLB schedule feed (operator 2026-11-16: "poll and push all minor league games
-- too").
--
-- CLUBS. The 120 Triple-A, Double-A, High-A and Single-A clubs (statsapi sportId 11, 12, 13, 14) are read
-- from the same MLB ticketing schedule as the 30 MLB clubs, with sport_id set to the club's level. Rookie
-- clubs (sportId 16: Arizona / Florida complex leagues, Dominican Summer League) are left out: the schedule
-- lists no games for them (complex games are free). Read-only sweep 2026-11-16: 119 of 120 clubs answered
-- with their 2027 home games (8,214 games); 8 clubs already carry single-game links.
-- LINKS. Minor league clubs link to ProVenue (mlb.tickets.com, by eventId= instead of pid=) and, for
-- Somerset, to Glitnir (so1.glitnirticketing.com stadiumg.php?…event_id=N). Both are one page per game
-- and are now kept as direct links; every other link stays a redirect, as before.
-- RATE. A tick that lands a read now also fires the next one (was: one tick lands, the next fires), so
-- the 150 clubs × 2 seasons still come round inside the 11-hour refresh.
-- MATCHING. After a read lands, only that club's games are matched to EVO and SeatGeek (was: the 1,000
-- earliest unmatched games of every club, on every tick — about 6 s a minute, and with 8,000 minor league
-- games that EVO does not list yet those 1,000 would have been the same games every time). One full pass
-- over every upcoming game runs once an hour (minute 30): EVO events are first narrowed by date and the
-- home club's name, and only those are normalised (24 s → 3.4 s on prod for 2,897 games). SeatGeek
-- matching now also accepts SeatGeek's 'MLB' and 'baseball' categories.
-- FEED. The view adds sport_id, level (mlb / aaa / aa / high_a / single_a), league_name and parent_org at
-- the end. The API serves MLB only unless the reader asks for a level, so existing readers see no change.
-- Nothing upstream is written (RULE 2): the collector's one GET is the same public schedule.

BEGIN;
SET LOCAL lock_timeout = '10s';

ALTER TABLE public.mlb_ticket_team
  ADD COLUMN IF NOT EXISTS sport_id        integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS league_name     text,
  ADD COLUMN IF NOT EXISTS parent_org_name text;
ALTER TABLE public.mlb_ticket_game
  ADD COLUMN IF NOT EXISTS sport_id integer NOT NULL DEFAULT 1;
CREATE INDEX IF NOT EXISTS mlb_ticket_game_home_date_idx ON public.mlb_ticket_game (home_team_id, game_date);

UPDATE public.mlb_ticket_team
   SET league_name = CASE WHEN team_id IN (108,110,111,114,116,117,118,133,136,139,140,141,142,145,147) THEN 'American League'
                          ELSE 'National League' END
 WHERE league_name IS NULL AND sport_id = 1;

INSERT INTO public.mlb_ticket_team (team_id, abbrev, full_name, sport_id, league_name, parent_org_name) VALUES
  (102, 'RR', 'Round Rock Express', 11, 'Pacific Coast League', 'Texas Rangers'),
  (105, 'SAC', 'Sacramento River Cats', 11, 'Pacific Coast League', 'San Francisco Giants'),
  (234, 'DUR', 'Durham Bulls', 11, 'International League', 'Tampa Bay Rays'),
  (235, 'MEM', 'Memphis Redbirds', 11, 'International League', 'St. Louis Cardinals'),
  (238, 'OKC', 'Oklahoma City Comets', 11, 'Pacific Coast League', 'Los Angeles Dodgers'),
  (342, 'ABQ', 'Albuquerque Isotopes', 11, 'Pacific Coast League', 'Colorado Rockies'),
  (400, 'LV', 'Las Vegas Aviators', 11, 'Pacific Coast League', 'Athletics'),
  (416, 'LOU', 'Louisville Bats', 11, 'International League', 'Cincinnati Reds'),
  (422, 'BUF', 'Buffalo Bisons', 11, 'International League', 'Toronto Blue Jays'),
  (431, 'GWN', 'Gwinnett Stripers', 11, 'International League', 'Atlanta Braves'),
  (445, 'COL', 'Columbus Clippers', 11, 'International League', 'Cleveland Guardians'),
  (451, 'IOW', 'Iowa Cubs', 11, 'International League', 'Chicago Cubs'),
  (484, 'IND', 'Indianapolis Indians', 11, 'International League', 'Pittsburgh Pirates'),
  (494, 'CLT', 'Charlotte Knights', 11, 'International League', 'Chicago White Sox'),
  (512, 'TOL', 'Toledo Mud Hens', 11, 'International League', 'Detroit Tigers'),
  (529, 'TAC', 'Tacoma Rainiers', 11, 'Pacific Coast League', 'Seattle Mariners'),
  (531, 'SWB', 'Scranton/Wilkes-Barre Highlanders', 11, 'International League', 'New York Yankees'),
  (533, 'WOR', 'Worcester Red Sox', 11, 'International League', 'Boston Red Sox'),
  (534, 'ROC', 'Rochester Red Wings', 11, 'International League', 'Washington Nationals'),
  (541, 'OMA', 'Omaha Storm Chasers', 11, 'International League', 'Kansas City Royals'),
  (552, 'SYR', 'Syracuse Mets', 11, 'International League', 'New York Mets'),
  (556, 'NAS', 'Nashville Sounds', 11, 'International League', 'Milwaukee Brewers'),
  (561, 'SL', 'Salt Lake Bees', 11, 'Pacific Coast League', 'Los Angeles Angels'),
  (564, 'JAX', 'Jacksonville Jumbo Shrimp', 11, 'International League', 'Miami Marlins'),
  (568, 'NOR', 'Norfolk Tides', 11, 'International League', 'Baltimore Orioles'),
  (1410, 'LHV', 'Lehigh Valley IronPigs', 11, 'International League', 'Philadelphia Phillies'),
  (1960, 'STP', 'St. Paul Saints', 11, 'International League', 'Minnesota Twins'),
  (2310, 'RNO', 'Reno Aces', 11, 'Pacific Coast League', 'Arizona Diamondbacks'),
  (4904, 'ELP', 'El Paso Chihuahuas', 11, 'Pacific Coast League', 'San Diego Padres'),
  (5434, 'SUG', 'Sugar Land Space Cowboys', 11, 'Pacific Coast League', 'Houston Astros'),
  (106, 'ERI', 'Erie SeaWolves', 12, 'Eastern League', 'Detroit Tigers'),
  (237, 'MID', 'Midland RockHounds', 12, 'Texas League', 'Athletics'),
  (247, 'BIR', 'Birmingham Barons', 12, 'Southern League', 'Chicago White Sox'),
  (260, 'TUL', 'Tulsa Drillers', 12, 'Texas League', 'Los Angeles Dodgers'),
  (402, 'AKR', 'Akron RubberDucks', 12, 'Eastern League', 'Cleveland Guardians'),
  (418, 'CHE', 'Chesapeake Baysox', 12, 'Eastern League', 'Baltimore Orioles'),
  (421, 'MTG', 'Montgomery Biscuits', 12, 'Southern League', 'Tampa Bay Rays'),
  (440, 'OZK', 'Ozarks Springbirds', 12, 'Texas League', 'St. Louis Cardinals'),
  (452, 'ALT', 'Altoona Curve', 12, 'Eastern League', 'Pittsburgh Pirates'),
  (463, 'NH', 'New Hampshire Fisher Cats', 12, 'Eastern League', 'Toronto Blue Jays'),
  (482, 'CC', 'Corpus Christi Hooks', 12, 'Texas League', 'Houston Astros'),
  (498, 'CHA', 'Chattanooga Lookouts', 12, 'Southern League', 'Cincinnati Reds'),
  (505, 'BNG', 'Binghamton Rumble Ponies', 12, 'Eastern League', 'New York Mets'),
  (510, 'SA', 'San Antonio Missions', 12, 'Texas League', 'San Diego Padres'),
  (522, 'REA', 'Reading Fightin Phils', 12, 'Eastern League', 'Philadelphia Phillies'),
  (538, 'HFD', 'Hartford Yard Goats', 12, 'Eastern League', 'Colorado Rockies'),
  (540, 'FRI', 'Frisco RoughRiders', 12, 'Texas League', 'Texas Rangers'),
  (546, 'POR', 'Portland Sea Dogs', 12, 'Eastern League', 'Boston Red Sox'),
  (547, 'HBG', 'Harrisburg Senators', 12, 'Eastern League', 'Washington Nationals'),
  (553, 'KNX', 'Knoxville Smokies', 12, 'Southern League', 'Chicago Cubs'),
  (559, 'RCT', 'Rocket City Trash Pandas', 12, 'Southern League', 'Los Angeles Angels'),
  (574, 'ARK', 'Arkansas Travelers', 12, 'Texas League', 'Seattle Mariners'),
  (1350, 'NWA', 'Northwest Arkansas Naturals', 12, 'Texas League', 'Kansas City Royals'),
  (1956, 'SOM', 'Somerset Patriots', 12, 'Eastern League', 'New York Yankees'),
  (3410, 'RIC', 'Richmond Flying Squirrels', 12, 'Eastern League', 'San Francisco Giants'),
  (3898, 'WCH', 'Wichita Wind Surge', 12, 'Texas League', 'Minnesota Twins'),
  (4124, 'PNS', 'Pensacola Blue Wahoos', 12, 'Southern League', 'Miami Marlins'),
  (5015, 'BLX', 'Biloxi Shuckers', 12, 'Southern League', 'Milwaukee Brewers'),
  (5368, 'AMA', 'Amarillo Sod Poodles', 12, 'Texas League', 'Arizona Diamondbacks'),
  (6325, 'COL', 'Columbus Clingstones', 12, 'Southern League', 'Atlanta Braves'),
  (403, 'EVE', 'Everett AquaSox', 13, 'Northwest League', 'Seattle Mariners'),
  (419, 'HIL', 'Hillsboro Hops', 13, 'Northwest League', 'Arizona Diamondbacks'),
  (426, 'WIL', 'Wilmington Blue Rocks', 13, 'South Atlantic League', 'Washington Nationals'),
  (427, 'JS', 'Jersey Shore BlueClaws', 13, 'South Atlantic League', 'Philadelphia Phillies'),
  (428, 'GVL', 'Greenville Drive', 13, 'South Atlantic League', 'Boston Red Sox'),
  (432, 'ROM', 'Rome Emperors', 13, 'South Atlantic League', 'Atlanta Braves'),
  (435, 'VAN', 'Vancouver Canadians', 13, 'Northwest League', 'Toronto Blue Jays'),
  (437, 'LC', 'Lake County Captains', 13, 'Midwest League', 'Cleveland Guardians'),
  (443, 'PEO', 'Peoria Chiefs', 13, 'Midwest League', 'St. Louis Cardinals'),
  (453, 'BRK', 'Brooklyn Cyclones', 13, 'South Atlantic League', 'New York Mets'),
  (456, 'GL', 'Great Lakes Loons', 13, 'Midwest League', 'Los Angeles Dodgers'),
  (459, 'DAY', 'Dayton Dragons', 13, 'Midwest League', 'Cincinnati Reds'),
  (460, 'TRI', 'Tri-City Dust Devils', 13, 'Northwest League', 'Los Angeles Angels'),
  (461, 'EUG', 'Eugene Emeralds', 13, 'Northwest League', 'San Francisco Giants'),
  (477, 'GBO', 'Greensboro Grasshoppers', 13, 'South Atlantic League', 'Pittsburgh Pirates'),
  (486, 'SPO', 'Spokane Indians', 13, 'Northwest League', 'Colorado Rockies'),
  (492, 'CR', 'Cedar Rapids Kernels', 13, 'Midwest League', 'Minnesota Twins'),
  (493, 'FRE', 'Frederick Keys', 13, 'South Atlantic League', 'Baltimore Orioles'),
  (499, 'LAN', 'Lansing Lugnuts', 13, 'Midwest League', 'Athletics'),
  (537, 'HV', 'Hudson Valley Renegades', 13, 'South Atlantic League', 'New York Yankees'),
  (550, 'SB', 'South Bend Cubs', 13, 'Midwest League', 'Chicago Cubs'),
  (554, 'BEL', 'Beloit Sky Carp', 13, 'Midwest League', 'Miami Marlins'),
  (565, 'QC', 'Quad Cities River Bandits', 13, 'Midwest League', 'Kansas City Royals'),
  (572, 'WIS', 'Wisconsin Timber Rattlers', 13, 'Midwest League', 'Milwaukee Brewers'),
  (573, 'ASH', 'Asheville Tourists', 13, 'South Atlantic League', 'Houston Astros'),
  (580, 'WS', 'Winston-Salem Dash', 13, 'South Atlantic League', 'Chicago White Sox'),
  (582, 'WM', 'West Michigan Whitecaps', 13, 'Midwest League', 'Detroit Tigers'),
  (584, 'FW', 'Fort Wayne TinCaps', 13, 'Midwest League', 'San Diego Padres'),
  (2498, 'BG', 'Bowling Green Hot Rods', 13, 'South Atlantic League', 'Tampa Bay Rays'),
  (6324, 'HCS', 'Hub City Spartanburgers', 13, 'South Atlantic League', 'Texas Rangers'),
  (103, 'LE', 'Lake Elsinore Storm', 14, 'California League', 'San Diego Padres'),
  (233, 'CHS', 'Charleston RiverDogs', 14, 'Carolina League', 'Tampa Bay Rays'),
  (249, 'WIL', 'Wilson Warbirds', 14, 'Carolina League', 'Milwaukee Brewers'),
  (259, 'FRE', 'Fresno Grizzlies', 14, 'California League', 'Colorado Rockies'),
  (279, 'PMB', 'Palm Beach Cardinals', 14, 'Florida State League', 'St. Louis Cardinals'),
  (401, 'IE', 'Inland Empire 66ers', 14, 'California League', 'Seattle Mariners'),
  (414, 'SAL', 'Salem RidgeYaks', 14, 'Carolina League', 'Boston Red Sox'),
  (424, 'DUN', 'Dunedin Blue Jays', 14, 'Florida State League', 'Toronto Blue Jays'),
  (436, 'FBG', 'Fredericksburg Nationals', 14, 'Carolina League', 'Washington Nationals'),
  (448, 'HIC', 'Hickory Crawdads', 14, 'Carolina League', 'Texas Rangers'),
  (450, 'DBT', 'Daytona Tortugas', 14, 'Florida State League', 'Cincinnati Reds'),
  (476, 'SJ', 'San Jose Giants', 14, 'California League', 'San Francisco Giants'),
  (478, 'AUG', 'Augusta GreenJackets', 14, 'Carolina League', 'Atlanta Braves'),
  (479, 'JUP', 'Jupiter Hammerheads', 14, 'Florida State League', 'Miami Marlins'),
  (481, 'HC', 'Hill City Howlers', 14, 'Carolina League', 'Cleveland Guardians'),
  (487, 'KAN', 'Kannapolis Cannon Ballers', 14, 'Carolina League', 'Chicago White Sox'),
  (507, 'SLU', 'St. Lucie Mets', 14, 'Florida State League', 'New York Mets'),
  (509, 'FTM', 'Fort Myers Mighty Mussels', 14, 'Florida State League', 'Minnesota Twins'),
  (516, 'VIS', 'Visalia Rawhide', 14, 'California League', 'Arizona Diamondbacks'),
  (521, 'MB', 'Myrtle Beach Pelicans', 14, 'Carolina League', 'Chicago Cubs'),
  (524, 'STK', 'Stockton Ports', 14, 'California League', 'Athletics'),
  (526, 'RC', 'Rancho Cucamonga Quakes', 14, 'California League', 'Los Angeles Angels'),
  (548, 'DEL', 'Delmarva Shorebirds', 14, 'Carolina League', 'Baltimore Orioles'),
  (566, 'CLR', 'Clearwater Threshers', 14, 'Florida State League', 'Philadelphia Phillies'),
  (570, 'LAK', 'Lakeland Flying Tigers', 14, 'Florida State League', 'Detroit Tigers'),
  (587, 'TAM', 'Tampa Tarpons', 14, 'Florida State League', 'New York Yankees'),
  (3390, 'BRD', 'Bradenton Marauders', 14, 'Florida State League', 'Pittsburgh Pirates'),
  (3705, 'COL', 'Columbia Fireflies', 14, 'Carolina League', 'Kansas City Royals'),
  (3712, 'FAY', 'Fayetteville Woodpeckers', 14, 'Carolina League', 'Houston Astros'),
  (6482, 'ONT', 'Ontario Tower Buzzers', 14, 'California League', 'Los Angeles Dodgers')
ON CONFLICT (team_id) DO UPDATE SET abbrev = EXCLUDED.abbrev, full_name = EXCLUDED.full_name,
  sport_id = EXCLUDED.sport_id, league_name = EXCLUDED.league_name, parent_org_name = EXCLUDED.parent_org_name;

-- one page per game: Ticketmaster event, ProVenue (pid= or eventId=), Glitnir (event_id=)
CREATE OR REPLACE FUNCTION public.mlb_ticket_direct_url(p_url text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_url ~ '^https://www\.ticketmaster\.com/event/[0-9A-Za-z]+/?$' THEN p_url
    WHEN p_url ~* '^https://mlb\.tickets\.com/?\?(.*&)?(pid|eventId)=[0-9]+' THEN p_url
    WHEN p_url ~* '^https://so1\.glitnirticketing\.com/soticket/web/stadiumg\.php\?(.*&)?event_id=[0-9]+' THEN p_url
  END
$$;

CREATE OR REPLACE FUNCTION public.mlb_ticket_fire(p_team integer, p_season integer)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE v_req bigint; v_sport integer;
BEGIN
  SELECT sport_id INTO v_sport FROM public.mlb_ticket_team WHERE team_id = p_team;
  SELECT net.http_get(
           url := 'https://www.ticketing-client.com/ticketing-client/json/EventTicketPromotionPrice.tiksrv',
           params := jsonb_build_object(
             'team_id', p_team::text, 'home_team_id', p_team::text, 'sport_id', coalesce(v_sport, 1)::text,
             'display_in', 'singlegame', 'ticket_category', 'Tickets', 'site_section', 'Default',
             'sub_category', 'Default', 'leave_empty_games', 'true', 'event_type', 'T',
             'begin_date', p_season || '0101', 'end_date', p_season || '1231', 'year', p_season::text),
           timeout_milliseconds := 60000) INTO v_req;
  UPDATE public.mlb_ticket_sync SET pending_request_id = v_req, pending_since = now()
   WHERE team_id = p_team AND season = p_season;
  RETURN v_req;
END $$;

-- matchers: p_team limits a pass to one home club's games; p_limit NULL = no limit
DROP FUNCTION IF EXISTS public.mlb_ticket_match(integer);
DROP FUNCTION IF EXISTS public.mlb_ticket_match_sg(integer);

CREATE FUNCTION public.mlb_ticket_match_sg(p_limit integer DEFAULT NULL, p_team integer DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_n integer;
BEGIN
  UPDATE public.mlb_ticket_game g
     SET sg_event_id = NULL, sg_match_method = NULL, sg_matched_at = NULL, changed_at = now()
    FROM public.sg_events_canonical c
   WHERE c.sg_event_id = g.sg_event_id AND c.sg_event_date IS DISTINCT FROM g.game_date
     AND (p_team IS NULL OR g.home_team_id = p_team);

  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.is_tbd, g.game_time_utc,
           public.mlb_ticket_norm_name(g.away_name || ' at ' || g.home_name) AS nm
      FROM public.mlb_ticket_game g
     WHERE g.sg_event_id IS NULL AND g.game_date >= current_date - 1
       AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL
       AND (p_team IS NULL OR g.home_team_id = p_team)
     ORDER BY g.game_date
     LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE greatest(p_limit, 0) END),
  cand AS (
    SELECT t.schedule_id, c.sg_event_id,
           count(*) OVER (PARTITION BY t.schedule_id) AS n_day,
           (NOT t.is_tbd AND date_trunc('minute', c.sg_datetime_utc) = date_trunc('minute', t.game_time_utc)) AS same_minute
      FROM todo t
      JOIN public.sg_events_canonical c
        ON lower(c.sg_category) IN ('mlb', 'baseball', 'minor league baseball', 'minor_league_baseball', 'milb')
       AND c.sg_event_date = t.game_date
       AND public.mlb_ticket_norm_name(c.sg_event_name) = t.nm),
  pick AS (
    SELECT schedule_id, min(sg_event_id) AS sg_event_id, 'name_date' AS method
      FROM cand WHERE n_day = 1 GROUP BY schedule_id
    UNION ALL
    SELECT schedule_id, min(sg_event_id), 'name_date_time'
      FROM cand WHERE n_day > 1 AND same_minute
     GROUP BY schedule_id HAVING count(*) = 1)
  UPDATE public.mlb_ticket_game g
     SET sg_event_id = p.sg_event_id, sg_match_method = p.method, sg_matched_at = now(), changed_at = now()
    FROM pick p
   WHERE g.schedule_id = p.schedule_id AND g.sg_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o
                      WHERE o.sg_event_id = p.sg_event_id AND o.schedule_id <> g.schedule_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE FUNCTION public.mlb_ticket_match(p_limit integer DEFAULT NULL, p_team integer DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_n integer;
BEGIN
  UPDATE public.mlb_ticket_game g
     SET tevo_event_id = NULL, tevo_matched_at = NULL, tevo_match_method = NULL, changed_at = now()
    FROM public.events e
   WHERE e.id = g.tevo_event_id
     AND (p_team IS NULL OR g.home_team_id = p_team)
     AND (left(e.occurs_at_local, 10) <> g.game_date::text OR coalesce(e.state, 'shown') = 'ignored');

  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.is_tbd, lower(g.home_name) AS home_lc,
           to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI') AS want_min,
           public.mlb_ticket_norm_name(g.away_name || ' at ' || g.home_name) AS nm
      FROM public.mlb_ticket_game g
     WHERE g.tevo_event_id IS NULL AND g.game_date >= current_date - 1
       AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL
       AND (p_team IS NULL OR g.home_team_id = p_team)
     ORDER BY g.game_date
     LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE greatest(p_limit, 0) END),
  -- EVO events on the game's date that name the home club; only these are normalised
  near AS MATERIALIZED (
    SELECT t.schedule_id, t.is_tbd, t.want_min, t.nm, e.id, e.name, e.occurs_at_local
      FROM todo t
      JOIN public.events e ON left(e.occurs_at_local, 10) = t.game_date::text
                          AND strpos(lower(e.name), t.home_lc) > 0
                          AND coalesce(e.state, 'shown') <> 'ignored'),
  cand AS (
    SELECT n.schedule_id, n.id,
           count(*) OVER (PARTITION BY n.schedule_id) AS n_day,
           (NOT n.is_tbd AND left(n.occurs_at_local, 16) = n.want_min) AS same_minute
      FROM near n
     WHERE public.mlb_ticket_norm_name(n.name) = n.nm),
  pick AS (
    SELECT schedule_id, min(id) AS tevo_event_id, 'name_date' AS method
      FROM cand WHERE n_day = 1 GROUP BY schedule_id
    UNION ALL
    SELECT schedule_id, min(id), 'name_date_time'
      FROM cand WHERE n_day > 1 AND same_minute
     GROUP BY schedule_id HAVING count(*) = 1)
  UPDATE public.mlb_ticket_game g
     SET tevo_event_id = p.tevo_event_id, tevo_matched_at = now(), tevo_match_method = p.method, changed_at = now()
    FROM pick p
   WHERE g.schedule_id = p.schedule_id AND g.tevo_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o
                      WHERE o.tevo_event_id = p.tevo_event_id AND o.schedule_id <> g.schedule_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n + public.mlb_ticket_match_sg(p_limit, p_team);
END $$;

CREATE OR REPLACE FUNCTION public.mlb_ticket_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  s       public.mlb_ticket_sync;
  r       record;
  j       jsonb;
  v_rows  int := 0;
  v_err   text;
  v_sport int;
  v_out   jsonb := '{}'::jsonb;
  v_now   timestamp := now() AT TIME ZONE 'America/New_York';
  v_year  int := extract(year FROM v_now)::int;
  v_seasons int[];
BEGIN
  -- seasons that still have games: this one until 31 October, and the next
  v_seasons := CASE WHEN extract(month FROM v_now) >= 11 THEN ARRAY[v_year + 1] ELSE ARRAY[v_year, v_year + 1] END;
  INSERT INTO public.mlb_ticket_sync (team_id, season)
  SELECT t.team_id, y FROM public.mlb_ticket_team t CROSS JOIN unnest(v_seasons) y
   WHERE t.active
  ON CONFLICT DO NOTHING;

  -- 1. a read in flight: land it
  SELECT * INTO s FROM public.mlb_ticket_sync WHERE pending_request_id IS NOT NULL
   ORDER BY pending_since LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF FOUND THEN
    SELECT x.status_code, x.content INTO r FROM net._http_response x WHERE x.id = s.pending_request_id;
    IF NOT FOUND THEN
      IF s.pending_since > now() - interval '3 minutes' THEN
        RETURN jsonb_build_object('state', 'waiting', 'team', s.team_id, 'season', s.season);
      END IF;
      r := NULL;
    END IF;
    j := CASE WHEN r IS NOT NULL THEN public.safe_jsonb(r.content) END;
    IF r IS NULL OR r.status_code IS DISTINCT FROM 200 OR j->'events' IS NULL OR j->'events' ? 'error' THEN
      v_err := format('http %s %s', coalesce(r.status_code::text, 'lost'), left(coalesce(r.content, ''), 200));
      UPDATE public.mlb_ticket_sync
         SET pending_request_id = NULL, tries = tries + 1, last_error = v_err, last_error_at = now()
       WHERE team_id = s.team_id AND season = s.season;
      v_out := jsonb_build_object('state', 'error', 'team', s.team_id, 'season', s.season, 'error', v_err);
    ELSE
      SELECT sport_id INTO v_sport FROM public.mlb_ticket_team WHERE team_id = s.team_id;
      WITH items AS (
        SELECT g FROM jsonb_array_elements(
                 CASE jsonb_typeof(j->'events'->'game') WHEN 'array' THEN j->'events'->'game'
                      WHEN 'object' THEN jsonb_build_array(j->'events'->'game') ELSE '[]'::jsonb END) g
         WHERE (g->>'schedule_id') ~ '^\d+$'),
      links AS (
        SELECT i.g,
               (SELECT tl FROM jsonb_array_elements(CASE jsonb_typeof(i.g->'ticket_link') WHEN 'array' THEN i.g->'ticket_link'
                                                 WHEN 'object' THEN jsonb_build_array(i.g->'ticket_link') ELSE '[]'::jsonb END) tl
                 WHERE coalesce(tl->>'tlink', '') <> ''
                 ORDER BY (public.mlb_ticket_direct_url(tl->>'tlink') IS NOT NULL) DESC,   -- a direct link first
                          (upper(coalesce(tl->>'ticket_category', '')) = 'TICKETS') DESC LIMIT 1) AS tl
          FROM items i),
      parsed AS (
        SELECT l.g, l.tl, l.tl->>'tlink' AS raw_link,
               (l.g->>'tbd_flag') = 'Y' AS tbd,
               CASE WHEN l.g->>'game_date' ~ '^\d{4}-\d\d-\d\d$' THEN (l.g->>'game_date')::date END AS gdate,
               CASE WHEN l.g->>'game_time_local' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (l.g->>'game_time_local')::timestamp END AS tlocal,
               CASE WHEN l.g->>'game_time' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                    THEN to_timestamp(l.g->>'game_time', 'YYYYMMDD HH12:MI:SS AM')::timestamp AT TIME ZONE 'UTC' END AS tutc
          FROM links l)
      INSERT INTO public.mlb_ticket_game AS t (
        schedule_id, mlb_game_id, season, sport_id, game_type, game_type_name, game_date, game_time_local, time_zone_local,
        game_time_utc, is_tbd, game_number, if_necessary, status, descr, home_team_id, home_name, home_abbrev,
        away_team_id, away_name, away_abbrev, venue_id, venue_name, venue_city, venue_postal_code,
        ticket_link_raw, ticket_url, ticket_url_kind, on_sale_start, on_sale_end, raw, last_seen_at, changed_at)
      SELECT (p.g->>'schedule_id')::bigint, p.g->>'game_id',
             coalesce(extract(year FROM p.gdate)::int, s.season), coalesce(v_sport, 1),
             p.g->>'game_type', p.g->>'gt_name_short',
             p.gdate, p.tlocal, p.g->>'time_zone_local', p.tutc, p.tbd,
             CASE WHEN p.g->>'game_number' ~ '^\d+$' THEN (p.g->>'game_number')::int END,
             (p.g->>'if_necessary') = 'Y', p.g->>'status', nullif(p.g->>'descr', ''),
             CASE WHEN p.g->>'home_team_id' ~ '^\d+$' THEN (p.g->>'home_team_id')::int END,
             p.g->>'home_name_full', p.g->>'home_name_abbrev',
             CASE WHEN p.g->>'away_team_id' ~ '^\d+$' THEN (p.g->>'away_team_id')::int END,
             p.g->>'away_name_full', p.g->>'away_name_abbrev',
             CASE WHEN p.g->>'venue_id' ~ '^\d+$' THEN (p.g->>'venue_id')::int END,
             p.g->>'venue_name', p.g->>'venue_city', p.g->>'venue_postal_code',
             p.raw_link, public.mlb_ticket_direct_url(p.raw_link),
             CASE WHEN p.raw_link IS NULL THEN NULL
                  WHEN public.mlb_ticket_direct_url(p.raw_link) IS NOT NULL THEN 'direct' ELSE 'redirect' END,
             CASE WHEN p.tl->>'on_sale_start_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                  THEN to_timestamp(p.tl->>'on_sale_start_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
             CASE WHEN p.tl->>'on_sale_end_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                  THEN to_timestamp(p.tl->>'on_sale_end_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
             p.g - 'promotion', now(), now()
        FROM parsed p
      ON CONFLICT (schedule_id) DO UPDATE SET
        mlb_game_id = EXCLUDED.mlb_game_id, season = EXCLUDED.season, sport_id = EXCLUDED.sport_id,
        game_type = EXCLUDED.game_type,
        game_type_name = EXCLUDED.game_type_name, game_date = EXCLUDED.game_date,
        game_time_local = EXCLUDED.game_time_local, time_zone_local = EXCLUDED.time_zone_local,
        game_time_utc = EXCLUDED.game_time_utc, is_tbd = EXCLUDED.is_tbd, game_number = EXCLUDED.game_number,
        if_necessary = EXCLUDED.if_necessary, status = EXCLUDED.status, descr = EXCLUDED.descr,
        home_team_id = EXCLUDED.home_team_id, home_name = EXCLUDED.home_name, home_abbrev = EXCLUDED.home_abbrev,
        away_team_id = EXCLUDED.away_team_id, away_name = EXCLUDED.away_name, away_abbrev = EXCLUDED.away_abbrev,
        venue_id = EXCLUDED.venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city,
        venue_postal_code = EXCLUDED.venue_postal_code,
        ticket_link_raw = EXCLUDED.ticket_link_raw, ticket_url = EXCLUDED.ticket_url, ticket_url_kind = EXCLUDED.ticket_url_kind,
        on_sale_start = EXCLUDED.on_sale_start, on_sale_end = EXCLUDED.on_sale_end, raw = EXCLUDED.raw,
        last_seen_at = now(),
        changed_at = CASE WHEN (t.game_date, t.game_time_local, t.game_time_utc, t.is_tbd, t.game_number, t.status,
                                t.home_team_id, t.away_team_id, t.venue_id, t.ticket_url, t.on_sale_start, t.game_type)
                               IS DISTINCT FROM
                               (EXCLUDED.game_date, EXCLUDED.game_time_local, EXCLUDED.game_time_utc, EXCLUDED.is_tbd,
                                EXCLUDED.game_number, EXCLUDED.status, EXCLUDED.home_team_id, EXCLUDED.away_team_id,
                                EXCLUDED.venue_id, EXCLUDED.ticket_url, EXCLUDED.on_sale_start, EXCLUDED.game_type)
                          THEN now() ELSE t.changed_at END,
        -- a game whose date moved is matched again
        tevo_event_id     = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_event_id END,
        tevo_matched_at   = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_matched_at END,
        tevo_match_method = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_match_method END;
      GET DIAGNOSTICS v_rows = ROW_COUNT;

      UPDATE public.mlb_ticket_sync
         SET pending_request_id = NULL, tries = 0, last_ok_at = now(), last_games = v_rows, last_error = NULL
       WHERE team_id = s.team_id AND season = s.season;
      PERFORM public.mlb_ticket_match(NULL, s.team_id);          -- this club's games only
      v_out := jsonb_build_object('state', 'landed', 'team', s.team_id, 'season', s.season, 'games', v_rows);
    END IF;
  END IF;

  -- once an hour: every upcoming game, for EVO / SeatGeek events created since
  IF extract(minute FROM now()) = 30 THEN
    v_out := v_out || jsonb_build_object('matched', public.mlb_ticket_match(NULL, NULL));
  END IF;

  -- 2. fire the next read: the club × season least recently read, once it is 11 hours old (errors retry after 30 min)
  SELECT * INTO s FROM public.mlb_ticket_sync
   WHERE season = ANY (v_seasons) AND pending_request_id IS NULL
     AND (last_ok_at IS NULL OR last_ok_at < now() - interval '11 hours')
     AND (last_error_at IS NULL OR last_error_at < now() - interval '30 minutes' OR last_ok_at > last_error_at)
   ORDER BY last_ok_at NULLS FIRST, team_id, season
   LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN
    RETURN CASE WHEN v_out = '{}'::jsonb THEN jsonb_build_object('state', 'idle') ELSE v_out END;
  END IF;
  PERFORM public.mlb_ticket_fire(s.team_id, s.season);
  RETURN CASE WHEN v_out = '{}'::jsonb THEN jsonb_build_object('state', 'fired') ELSE v_out END
         || jsonb_build_object('fired_team', s.team_id, 'fired_season', s.season);
END $$;

CREATE OR REPLACE VIEW public.v_mlb_schedule_feed
WITH (security_invoker = true) AS
WITH hub AS (   -- one hub row per TEvo event of a feed game, curated first; read once, hash-joined
  SELECT DISTINCT ON (a.tevo_event_id)
         a.tevo_event_id, a.aq_short_event_id, a.sg_event_id, a.sh_event_id, a.vivid_event_id,
         a.tm_event_id, a.gotickets_event_id
    FROM public.aq_event_map a
   WHERE a.tevo_event_id IN (SELECT m.tevo_event_id FROM public.mlb_ticket_game m
                              WHERE m.tevo_event_id IS NOT NULL AND m.game_date >= current_date - 1)
   ORDER BY a.tevo_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST)
SELECT g.schedule_id                                         AS mlb_schedule_id,
       g.mlb_game_id,
       g.season,
       CASE g.game_type WHEN 'R' THEN 'regular' WHEN 'S' THEN 'spring' WHEN 'E' THEN 'exhibition'
                        WHEN 'F' THEN 'wild_card' WHEN 'D' THEN 'division_series'
                        WHEN 'L' THEN 'league_championship' WHEN 'W' THEN 'world_series'
                        ELSE lower(coalesce(g.game_type_name, g.game_type)) END AS game_type,
       g.game_date,
       CASE WHEN g.is_tbd THEN NULL ELSE g.game_time_local END AS start_local,
       g.time_zone_local                                     AS time_zone,
       CASE WHEN g.is_tbd THEN NULL ELSE g.game_time_utc END AS start_utc,
       g.is_tbd                                              AS time_tbd,
       g.game_number                                         AS doubleheader_game,
       g.if_necessary,
       g.status,
       g.descr                                               AS description,
       g.home_team_id, g.home_name, g.home_abbrev,
       g.away_team_id, g.away_name, g.away_abbrev,
       g.venue_id, g.venue_name, g.venue_city, g.venue_postal_code,
       g.ticket_url,
       CASE WHEN g.ticket_url IS NOT NULL THEN g.on_sale_start END AS on_sale_start_et,
       g.tevo_event_id,
       g.tevo_match_method,
       e.occurs_at_local                                     AS tevo_start_local,
       CASE WHEN g.tevo_event_id IS NULL THEN NULL
            WHEN e.occurs_at_local ~ 'T00:00(:00)?$' THEN 'evo_date_only'
            WHEN g.is_tbd THEN 'mlb_tbd'
            WHEN left(e.occurs_at_local, 16) = to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI') THEN 'same'
            ELSE 'differs' END                               AS tevo_time_check,
       hub.aq_short_event_id,
       coalesce(g.sg_event_id, hub.sg_event_id)              AS sg_event_id,
       hub.sh_event_id, hub.vivid_event_id, hub.tm_event_id, hub.gotickets_event_id,
       CASE WHEN g.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || g.tevo_event_id END AS terminal_path,
       g.changed_at,
       g.last_seen_at,
       sg.sg_url,
       CASE WHEN g.sg_event_id IS NOT NULL THEN g.sg_match_method
            WHEN hub.sg_event_id IS NOT NULL THEN 'hub' END  AS sg_match_method,
       g.sport_id,
       CASE g.sport_id WHEN 1 THEN 'mlb' WHEN 11 THEN 'aaa' WHEN 12 THEN 'aa'
                       WHEN 13 THEN 'high_a' WHEN 14 THEN 'single_a' END AS level,
       ht.league_name,
       ht.parent_org_name                                    AS parent_org
  FROM public.mlb_ticket_game g
  LEFT JOIN public.mlb_ticket_team ht ON ht.team_id = g.home_team_id
  LEFT JOIN public.events e ON e.id = g.tevo_event_id
  LEFT JOIN hub ON hub.tevo_event_id = g.tevo_event_id
  LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = coalesce(g.sg_event_id, hub.sg_event_id)
 WHERE g.game_date >= current_date - 1;

REVOKE ALL ON FUNCTION public.mlb_ticket_match_sg(integer, integer), public.mlb_ticket_match(integer, integer),
                       public.mlb_ticket_fire(integer, integer), public.mlb_ticket_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_ticket_match_sg(integer, integer), public.mlb_ticket_match(integer, integer),
                          public.mlb_ticket_fire(integer, integer), public.mlb_ticket_tick() TO service_role;
REVOKE ALL ON public.v_mlb_schedule_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_mlb_schedule_feed TO service_role;

COMMIT;

-- VERIFY:
--   SELECT sport_id, count(*) FROM mlb_ticket_team GROUP BY 1;                       -- 1:30 11:30 12:30 13:30 14:30
--   SELECT level, count(*), count(ticket_url) FROM v_mlb_schedule_feed GROUP BY 1;   -- fills over ~4 h as the clubs are read
--   SELECT mlb_ticket_direct_url('https://mlb.tickets.com/?orgId=54891&agency=MILB_MPV&eventId=73904');  -- the url
-- ROLLBACK: re-apply 20261116220000's mlb_ticket_match_sg / mlb_ticket_match / view and 20261116200000's
--   mlb_ticket_tick / mlb_ticket_direct_url, 20261116190000's mlb_ticket_fire; DELETE FROM mlb_ticket_sync s
--   USING mlb_ticket_team t WHERE t.team_id = s.team_id AND t.sport_id <> 1; same for mlb_ticket_game and
--   mlb_ticket_team; DROP the new columns.
