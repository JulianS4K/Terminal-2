\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- Dates are relative to today so the scenario never ages out of the mapper's "from yesterday on" window.
CREATE FUNCTION d(n int) RETURNS date LANGUAGE sql AS $$ SELECT current_date + n $$;
CREATE FUNCTION at_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') || 'T' || hm || ':00' $$;
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$ SELECT (j - 'run_id')::text $$;

-- registries: six MLB clubs, two Triple-A clubs
INSERT INTO team_xref (tevo_performer_id, tevo_name, espn_league) VALUES
  (15533, 'New York Yankees', 'MLB'), (15535, 'Toronto Blue Jays', 'MLB'), (15552, 'Houston Astros', 'MLB'),
  (15553, 'Milwaukee Brewers', 'MLB'), (15532, 'Boston Red Sox', 'MLB'), (15539, 'Kansas City Royals', 'MLB');
INSERT INTO entity_performer_map VALUES (90001, 'Durham Bulls'), (90002, 'Charlotte Knights'), (90003, 'Peoria Chiefs'), (90004, 'Peoria Chiefs');

-- the TEvo mirror
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, performer_ids) VALUES
  (1, 'Toronto Blue Jays at New York Yankees',                     at_(10, '00:00'), 'shown',   5725, 'Yankee Stadium', '{15533,15535}'),  -- date-only placeholder
  (2, 'Toronto Blue Jays at New York Yankees',                     at_(10, '13:05'), 'shown',   5725, 'Yankee Stadium', '{15533,15535}'),  -- the real listing
  (3, 'Parking: Toronto Blue Jays at New York Yankees',            at_(10, '13:05'), 'shown',   5725, 'Yankee Stadium', '{15533,15535}'),
  (4, 'Boston Red Sox at New York Yankees',                        at_(11, '19:05'), 'shown',   5725, 'Yankee Stadium', '{15533,15532}'),
  (5, 'Arizona Diamondbacks at San Diego Padres (Home Opener)',    at_(10, '00:00'), 'shown',   2775, 'Petco Park',     NULL),
  (6, 'Houston Astros at Milwaukee Brewers',                       at_(12, '12:10'), 'shown',   1913, 'American Family Field', '{15553,15552}'),
  (7, 'Houston Astros at Milwaukee Brewers',                       at_(12, '18:40'), 'shown',   1913, 'American Family Field', '{15553,15552}'),
  (8, 'Boston Red Sox at Kansas City Royals',                      at_(13, '12:00'), 'shown',   767,  'Kauffman Stadium', '{15539,15532}'),
  (9, 'Boston Red Sox at Kansas City Royals',                      at_(13, '13:00'), 'shown',   767,  'Kauffman Stadium', '{15539,15532}'),
  (10, 'Spring Training - Miami Marlins at Washington Nationals',  at_(14, '00:00'), 'shown',   50637, 'CACTI Park of the Palm Beaches', NULL),
  (11, 'Atlanta Braves at Los Angeles Dodgers',                    at_(15, '19:10'), 'shown',   414,  'Dodger Stadium', NULL),
  (12, 'San Diego Padres at Miami Marlins',                        at_(16, '18:40'), 'ignored', 15952, 'loanDepot Park', NULL),
  (13, 'Charlotte Knights at Durham Bulls',                        at_(17, '18:35'), 'shown',   6001, 'Durham Bulls Athletic Park', NULL),
  (14, 'Bronx Bombers Night',                                      at_(18, '19:05'), 'shown',   5725, 'Yankee Stadium', '{15533,15535}');  -- clubs only as performer ids

-- the hub: a curated row for event 2 (no SeatGeek id yet), a row tied to game 7 that points at event 11
INSERT INTO aq_event_map (aq_short_event_id, event_name, venue_name, event_date, aq_source, imported_at, tevo_event_id) VALUES
  ('K111', 'Toronto Blue Jays at New York Yankees', 'Yankee Stadium', at_(10, '13:05')::timestamp, 'aq_curated', now() - interval '30 days', 2),
  ('K999', 'Atlanta Braves at Los Angeles Dodgers', 'Dodger Stadium', at_(15, '19:10')::timestamp, 'system_seed', now() - interval '30 days', 11);
INSERT INTO mlb_hub_link (schedule_id, aq_short_event_id, tevo_event_id) VALUES (7, 'K999', 11);

-- SeatGeek: 501 links to the wrong EVO event (another day's game); 503 links to the doubleheader twin (fits: left alone); 502 has no link
INSERT INTO sg_events_canonical (sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_category, tevo_event_id, match_method) VALUES
  (501, 'Toronto Blue Jays at New York Yankees',  d(10), at_(10, '13:05')::timestamptz, 'mlb', 4,    'tevo_search_autotrack'),
  (502, 'Arizona Diamondbacks at San Diego Padres', d(10), NULL, 'mlb', NULL, NULL),
  (503, 'Houston Astros at Milwaukee Brewers',    d(12), at_(12, '12:10')::timestamptz, 'mlb', 7,    'matcher_v3_pm24h');

-- the games (game_time_utc written as the local wall time: the stub's tevo_event_utc reads local as UTC too)
INSERT INTO mlb_ticket_game (schedule_id, season, sport_id, game_type, game_date, game_time_local, game_time_utc, is_tbd, home_team_id, home_name, home_abbrev,
                             away_team_id, away_name, away_abbrev, venue_id, venue_name, venue_city, ticket_url, tevo_event_id, tevo_match_method, sg_event_id) VALUES
  (1, 2027, 1,  'R', d(10), at_(10, '13:05')::timestamp, at_(10, '13:05')::timestamptz, false, 147, 'New York Yankees', 'NYY', 141, 'Toronto Blue Jays', 'TOR', 3313, 'Yankee Stadium', 'Bronx', 'https://www.ticketmaster.com/event/0D0065557F262646', NULL, NULL, 501),
  (2, 2027, 1,  'R', d(10), at_(10, '03:33')::timestamp, at_(10, '03:33')::timestamptz, true,  135, 'San Diego Padres', 'SD', 109, 'Arizona Diamondbacks', 'AZ', 2680, 'Petco Park', 'San Diego', 'https://mlb.tickets.com?orgid=6&agency=MLB_MPV&pid=9750396', NULL, NULL, 502),
  (3, 2027, 1,  'R', d(12), at_(12, '12:10')::timestamp, at_(12, '12:10')::timestamptz, false, 158, 'Milwaukee Brewers', 'MIL', 117, 'Houston Astros', 'HOU', 32, 'American Family Field', 'Milwaukee', NULL, NULL, NULL, 503),
  (4, 2027, 1,  'R', d(12), at_(12, '18:40')::timestamp, at_(12, '18:40')::timestamptz, false, 158, 'Milwaukee Brewers', 'MIL', 117, 'Houston Astros', 'HOU', 32, 'American Family Field', 'Milwaukee', NULL, NULL, NULL, NULL),
  (5, 2027, 1,  'R', d(13), at_(13, '13:10')::timestamp, at_(13, '13:10')::timestamptz, false, 118, 'Kansas City Royals', 'KC', 111, 'Boston Red Sox', 'BOS', 7, 'Kauffman Stadium', 'Kansas City', NULL, NULL, NULL, NULL),
  (6, 2027, 1,  'S', d(14), at_(14, '13:05')::timestamp, at_(14, '13:05')::timestamptz, false, 117, 'Houston Astros', 'HOU', 147, 'New York Yankees', 'NYY', 5000, 'CACTI Park of the Palm Beaches', 'West Palm Beach', NULL, NULL, NULL, NULL),
  (7, 2027, 1,  'R', d(15), at_(15, '18:45')::timestamp, at_(15, '18:45')::timestamptz, false, 120, 'Washington Nationals', 'WSH', 146, 'Miami Marlins', 'MIA', 3309, 'Nationals Park', 'Washington', NULL, 11, 'name_date', NULL),
  (8, 2027, 1,  'R', d(16), at_(16, '18:40')::timestamp, at_(16, '18:40')::timestamptz, false, 146, 'Miami Marlins', 'MIA', 135, 'San Diego Padres', 'SD', 4169, 'loanDepot park', 'Miami', NULL, 12, 'name_date', NULL),
  (9, 2027, 11, 'R', d(17), at_(17, '18:35')::timestamp, at_(17, '18:35')::timestamptz, false, 234, 'Durham Bulls', 'DUR', 494, 'Charlotte Knights', 'CLT', 6700, 'Durham Bulls Athletic Park', 'Durham', 'https://www.milb.com/tickets?eventId=30768&x=1', NULL, NULL, NULL),
  (10, 2027, 1, 'R', d(18), at_(18, '19:05')::timestamp, at_(18, '19:05')::timestamptz, false, 147, 'New York Yankees', 'NYY', 141, 'Toronto Blue Jays', 'TOR', 3313, 'Yankee Stadium', 'Bronx', NULL, NULL, NULL, NULL);

\echo A dry run: the counts, and nothing written
SELECT out_(mlb_ticket_map(false));
SELECT count(*) AS audit_rows, (SELECT count(*) FROM mlb_ticket_game WHERE tevo_event_id IS NOT NULL) AS games_with_evo,
       (SELECT count(*) FROM aq_event_map) AS hub_rows, (SELECT tevo_event_id FROM sg_events_canonical WHERE sg_event_id = 501) AS sg501_tevo
  FROM mlb_map_audit;

\echo B the pass
SELECT out_(mlb_ticket_map(true));

\echo C games: EVO event + method (1 timed over placeholder, parking skipped; 2 suffix; 3+4 doubleheader by minute; 5 ambiguous; 6 other clubs; 7 wrong clubs dropped; 8 ignored dropped; 9 minor league; 10 by performer ids)
SELECT schedule_id, tevo_event_id, tevo_match_method FROM mlb_ticket_game ORDER BY 1;

\echo D clubs -> TEvo performers (MLB from team_xref, Triple-A by exact registry name; a name listed twice stays NULL)
SELECT team_id, full_name, tevo_performer_id FROM mlb_ticket_team WHERE team_id IN (147, 141, 234, 494, 443, 135) ORDER BY 1;

\echo E the sellers own ids
SELECT schedule_id, primary_seller, primary_event_id FROM mlb_ticket_game WHERE ticket_url IS NOT NULL ORDER BY 1;

\echo F parks learned from the games both sides name
SELECT mlb_venue_id, venue_name, tevo_venue_id, tevo_venue_name, games, method FROM mlb_venue_xref ORDER BY 1;
SELECT schedule_id, tevo_venue_id FROM mlb_ticket_game WHERE tevo_venue_id IS NOT NULL ORDER BY 1;

\echo G SeatGeek: 501 repointed to the games event, 502 filled, 503 (the twin, fits) left as it was
SELECT sg_event_id, tevo_event_id, match_method, match_confidence FROM sg_events_canonical ORDER BY 1;

\echo H the hub: K111 is tied to game 1 and carries its SeatGeek id; K999 let go of game 7; new system rows for the rest
SELECT a.aq_short_event_id ~ '^SYS-' AS system_row, a.tevo_event_id, l.schedule_id, a.sg_event_id, a.aq_source, a.primary_source, a.event_name
  FROM aq_event_map a LEFT JOIN mlb_hub_link l ON l.aq_short_event_id = a.aq_short_event_id ORDER BY l.schedule_id NULLS LAST, a.aq_short_event_id;

\echo I the audit trail of the pass
SELECT action, target, count(*), string_agg(schedule_id::text, ',' ORDER BY schedule_id) FROM mlb_map_audit GROUP BY 1, 2 ORDER BY 1, 2;
SELECT schedule_id, note FROM mlb_map_audit WHERE action = 'drop' ORDER BY 1;

\echo J a second pass changes nothing
SELECT out_(mlb_ticket_map(true) - 'hub_rows_missing');
SELECT count(*) FROM mlb_map_audit;

\echo K the game moves a day: its EVO match is dropped, its hub link with it; the next pass finds the moved listing
UPDATE mlb_ticket_game SET game_date = d(11), game_time_local = at_(11, '13:05')::timestamp, game_time_utc = at_(11, '13:05')::timestamptz WHERE schedule_id = 1;
SELECT out_(mlb_ticket_map(true) - 'hub_rows_missing' - 'venues_known');
SELECT schedule_id, tevo_event_id, tevo_match_method FROM mlb_ticket_game WHERE schedule_id = 1;
SELECT a.aq_short_event_id, a.tevo_event_id, l.schedule_id FROM aq_event_map a LEFT JOIN mlb_hub_link l ON l.aq_short_event_id = a.aq_short_event_id WHERE a.aq_short_event_id = 'K111';
UPDATE events SET occurs_at_local = at_(11, '13:05') WHERE id = 2;
SELECT out_(mlb_ticket_map(true) - 'hub_rows_missing' - 'venues_known');
SELECT schedule_id, tevo_event_id, tevo_match_method FROM mlb_ticket_game WHERE schedule_id = 1;
SELECT a.aq_short_event_id, a.tevo_event_id, l.schedule_id, a.sg_event_id FROM aq_event_map a LEFT JOIN mlb_hub_link l ON l.aq_short_event_id = a.aq_short_event_id WHERE a.tevo_event_id = 2;

\echo L who may run it
SELECT has_function_privilege('anon', 'mlb_ticket_map(boolean)', 'EXECUTE'), has_function_privilege('service_role', 'mlb_ticket_map(boolean)', 'EXECUTE'),
       (SELECT schedule FROM cron.job WHERE jobname = 'mlb_ticket_map_hourly');
