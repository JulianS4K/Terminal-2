\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- ESPN's ticket links (mig 20261117160000): the collector queues a league's periods and fires pages, lands a scoreboard
-- (teams, venue, start, the Vivid production and venue ids), matches games to TEvo events by time or day + both
-- nicknames + a fitting name (one candidate or nothing), and the map lets Vivid take the link: fill-only, audited.
CREATE FUNCTION d(n int) RETURNS date LANGUAGE sql AS $$ SELECT current_date + n $$;
CREATE FUNCTION at_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') || 'T' || hm || ':00' $$;
-- the ESPN UTC stamp of a New York wall-clock time
CREATE FUNCTION utc_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char((at_(n, hm)::timestamp AT TIME ZONE 'America/New_York') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"') $$;
CREATE FUNCTION game(id text, nm text, dt text, tv boolean, venue_id text, venue text, city text, st text, home_id text, home text, away_id text, away text, prod bigint, vvenue bigint) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('id', id, 'name', nm, 'shortName', '', 'date', dt, 'season', jsonb_build_object('year', 2027, 'type', 2),
    'competitions', jsonb_build_array(jsonb_build_object('timeValid', tv, 'neutralSite', false, 'status', jsonb_build_object('type', jsonb_build_object('name', 'STATUS_SCHEDULED')),
      'venue', jsonb_build_object('id', venue_id, 'fullName', venue, 'address', jsonb_build_object('city', city, 'state', st)),
      'competitors', jsonb_build_array(jsonb_build_object('id', home_id, 'homeAway', 'home', 'team', jsonb_build_object('displayName', home)),
                                       jsonb_build_object('id', away_id, 'homeAway', 'away', 'team', jsonb_build_object('displayName', away))),
      'tickets', CASE WHEN prod IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_object('summary', 'Tickets as low as $28', 'numberAvailable', 1706,
        'links', jsonb_build_array(jsonb_build_object('href', 'https://www.vividseats.com/x-tickets/production/' || prod || '?wsUser=717'),
                                   jsonb_build_object('href', 'https://www.vividseats.com/x-tickets/venue/' || vvenue || '?wsUser=717')))) END))) $$;

-- the TEvo mirror
INSERT INTO venue_timezone VALUES (1228, 'America/New_York', 'State Farm Arena'), (27950, 'America/New_York', 'Barclays Center'), (614, 'America/New_York', 'Rocket Arena');
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_name) VALUES
  (501, 'Charlotte Hornets at Atlanta Hawks',    at_(2, '19:00'), 'shown', 1228,  'State Farm Arena', 'Atlanta, GA',   'Atlanta Hawks'),
  (502, 'Boston Celtics at Atlanta Hawks',       at_(5, '18:30'), 'shown', 1228,  'State Farm Arena', 'Atlanta, GA',   'Atlanta Hawks'),
  (503, 'Orlando Magic at Brooklyn Nets',        at_(4, '19:30'), 'shown', 27950, 'Barclays Center',  'Brooklyn, NY',  'Brooklyn Nets'),
  (504, 'Indiana Pacers at Cleveland Cavaliers', at_(6, '13:00'), 'shown', 614,   'Rocket Arena',     'Cleveland, OH', 'Cleveland Cavaliers'),
  (505, 'Indiana Pacers at Cleveland Cavaliers', at_(6, '19:00'), 'shown', 614,   'Rocket Arena',     'Cleveland, OH', 'Cleveland Cavaliers'),
  (506, 'Miami Heat at Atlanta Hawks',           at_(7, '19:00'), 'shown', 1228,  'State Farm Arena', 'Atlanta, GA',   'Atlanta Hawks'),
  (507, 'Parking: Charlotte Hornets at Atlanta Hawks', at_(2, '19:00'), 'shown', 1228, 'State Farm Arena', 'Atlanta, GA', NULL);

-- Vivid: 1327 (State Farm Arena) unpaired; 9671 paired; 684 paired. 7419581 already matched by the catalogue mapper.
INSERT INTO vivid_catalog_venue (vivid_venue_id, name, city, state, country, tevo_venue_id, method) VALUES
  (1327, 'State Farm Arena', 'Atlanta', 'GA', 'US', NULL, NULL), (9671, 'Barclays Center', 'Brooklyn', 'NY', 'US', 27950, 'name_state'), (684, 'Rocket Arena', 'Cleveland', 'OH', 'US', 614, 'name_state');
INSERT INTO vivid_catalog_event (vivid_event_id, name, event_date, vivid_venue_id, tevo_event_id, tevo_match_method) VALUES
  (7419725, 'NBA Cup - Charlotte Hornets at Atlanta Hawks', d(2), 1327, NULL, NULL),
  (7419800, 'Boston Celtics at Atlanta Hawks', d(5), 1327, NULL, NULL),
  (7418387, 'NBA Cup - Orlando Magic at Brooklyn Nets', d(4), 9671, NULL, NULL),
  (7419581, 'NBA Cup - Indiana Pacers at Cleveland Cavaliers', d(6), 684, 505, 'venue_time_name'),
  (7419900, 'Miami Heat at Atlanta Hawks', d(12), 1327, NULL, NULL);          -- Vivid has the wrong day: no fill

\echo A one league, a 60-day horizon: the first tick queues the periods and fires the pages (nothing to land yet)
UPDATE espn_ticket_league SET active = false WHERE espn_league <> 'NBA';
UPDATE espn_ticket_league SET horizon_days = 60 WHERE espn_league = 'NBA';
SELECT espn_ticket_tick();
SELECT espn_league, count(*) AS periods, count(pending_request_id) AS in_flight, min(length(period)) AS period_len FROM espn_ticket_sync GROUP BY 1;
SELECT url, params->>'dates' AS dates, params->>'limit' AS lim FROM net.sent ORDER BY id LIMIT 1;

\echo B the responses arrive: the page of this month carries six games (one bracket game with TBD sides, one without a ticket link), the others are empty
INSERT INTO net._http_response (id, status_code, content)
SELECT s.pending_request_id, 200,
       CASE WHEN s.period = to_char(current_date, 'YYYYMM') THEN jsonb_build_object('events', jsonb_build_array(
         game('401909305', 'Charlotte Hornets at Atlanta Hawks',    utc_(2, '19:00'), true,  '1', 'State Farm Arena', 'Atlanta', 'GA', '1', 'Atlanta Hawks', '30', 'Charlotte Hornets', 7419725, 1327),
         game('401909400', 'Boston Celtics at Atlanta Hawks',       utc_(5, '18:30'), true,  '1', 'State Farm Arena', 'Atlanta', 'GA', '1', 'Atlanta Hawks', '2',  'Boston Celtics',    7419800, 1327),
         game('401909306', 'Orlando Magic at Brooklyn Nets',        to_char(d(4), 'YYYY-MM-DD') || 'T05:00Z', false, '2', 'Barclays Center', 'Brooklyn', 'NY', '17', 'Brooklyn Nets', '19', 'Orlando Magic', 7418387, 9671),
         game('401909307', 'Indiana Pacers at Cleveland Cavaliers', to_char(d(6), 'YYYY-MM-DD') || 'T05:00Z', false, '3', 'Rocket Arena', 'Cleveland', 'OH', '5', 'Cleveland Cavaliers', '11', 'Indiana Pacers', 7419581, 684),
         game('401909500', 'Miami Heat at Atlanta Hawks',           utc_(7, '19:00'), true,  '1', 'State Farm Arena', 'Atlanta', 'GA', '1', 'Atlanta Hawks', '14', 'Miami Heat',        7419900, 1327),
         game('401909600', 'TBD at TBD',                            utc_(9, '19:00'), true,  '1', 'State Farm Arena', 'Atlanta', 'GA', '-1', 'TBD', '-1', 'TBD', NULL, NULL)))::text
            ELSE '{"events": []}' END
  FROM espn_ticket_sync s WHERE s.pending_request_id IS NOT NULL;
SELECT espn_ticket_tick();
SELECT espn_event_id, name, ((game_at_utc AT TIME ZONE 'America/New_York')::date - current_date) || ' ' || to_char(game_at_utc AT TIME ZONE 'America/New_York', 'HH24:MI') AS ny_day_time, time_valid, vivid_production_id, vivid_venue_id, tevo_event_id, tevo_match_method FROM espn_ticket_game ORDER BY 1;
\echo B1 (305, 400, 500 by time; 306 by day, the time unknown; 307 has two EVO listings that day and no time: none; 600 has no sides)

\echo C the map, dry run then live: 7419725 and 7419800 take the EVO ids of their games; 7419900 does not (the Vivid day is wrong); game 307 takes 505 from the Vivid match; venue 1327 pairs through its two matched games
SELECT espn_ticket_map(false) - 'run_id';
SELECT espn_ticket_map(true) - 'run_id';
SELECT vivid_event_id, tevo_event_id, tevo_match_method FROM vivid_catalog_event ORDER BY 1;
SELECT espn_event_id, tevo_event_id, tevo_match_method FROM espn_ticket_game WHERE espn_event_id = '401909307';
SELECT vivid_venue_id, tevo_venue_id, method FROM vivid_catalog_venue ORDER BY 1;
SELECT action, target, target_key, new_tevo, note FROM vivid_catalog_audit ORDER BY id;
\echo C1 a second map writes nothing
SELECT espn_ticket_map(true) - 'run_id';

\echo D a refresh that moves a game by more than an hour drops its match; one that keeps the time keeps it; a page that fails is recorded and retried later
UPDATE espn_ticket_sync SET last_ok_at = now() - interval '1 day';
SELECT espn_ticket_tick();
INSERT INTO net._http_response (id, status_code, content)
SELECT s.pending_request_id, CASE WHEN s.period = to_char(current_date, 'YYYYMM') THEN 200 ELSE 500 END,
       CASE WHEN s.period = to_char(current_date, 'YYYYMM') THEN jsonb_build_object('events', jsonb_build_array(
         game('401909305', 'Charlotte Hornets at Atlanta Hawks', utc_(2, '21:30'), true, '1', 'State Farm Arena', 'Atlanta', 'GA', '1', 'Atlanta Hawks', '30', 'Charlotte Hornets', 7419725, 1327),
         game('401909400', 'Boston Celtics at Atlanta Hawks',    utc_(5, '18:30'), true, '1', 'State Farm Arena', 'Atlanta', 'GA', '1', 'Atlanta Hawks', '2',  'Boston Celtics',    7419800, 1327)))::text
            ELSE 'upstream error' END
  FROM espn_ticket_sync s WHERE s.pending_request_id IS NOT NULL;
SELECT espn_ticket_tick();
SELECT espn_event_id, ((game_at_utc AT TIME ZONE 'America/New_York')::date - current_date) || ' ' || to_char(game_at_utc AT TIME ZONE 'America/New_York', 'HH24:MI') AS ny_day_time, tevo_event_id, tevo_match_method FROM espn_ticket_game WHERE espn_event_id IN ('401909305', '401909400') ORDER BY 1;
SELECT period = to_char(current_date, 'YYYYMM') AS this_month, tries, last_error IS NOT NULL AS errored, pending_request_id IS NULL AS settled FROM espn_ticket_sync ORDER BY period;

\echo E the review view; who may run what; the crons
SELECT espn_event_id, vivid_name, vivid_method, game_method, evo_name FROM v_espn_ticket_link ORDER BY espn_event_id;
SELECT has_function_privilege('anon', 'espn_ticket_tick()', 'EXECUTE'), has_function_privilege('service_role', 'espn_ticket_map(boolean)', 'EXECUTE'), has_table_privilege('anon', 'espn_ticket_game', 'SELECT');
SELECT jobname, schedule FROM cron.job ORDER BY 1;
