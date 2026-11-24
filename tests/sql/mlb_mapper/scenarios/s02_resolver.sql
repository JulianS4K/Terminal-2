\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- mig 20261117100000: the schedule inside the resolver — identity for SeatGeek ids, doubleheader twins, time flags,
-- removed rows leaving the hub, stadium events matched through the park's known EVO venue.
CREATE FUNCTION d(n int) RETURNS date LANGUAGE sql AS $$ SELECT current_date + n $$;
CREATE FUNCTION at_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') || 'T' || hm || ':00' $$;
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$ SELECT (j - 'run_id' - 'hub_rows_missing' - 'venues_known' - 'games_venue_set' - 'primary_ids_set')::text $$;

INSERT INTO team_xref (tevo_performer_id, tevo_name, espn_league) VALUES
  (15533, 'New York Yankees', 'MLB'), (15535, 'Toronto Blue Jays', 'MLB'), (15532, 'Boston Red Sox', 'MLB');

-- the TEvo mirror: a doubleheader (21 at 13:05, 22 at 19:05), a listing 25 minutes off MLB's start (23), a noon
-- placeholder (24), a concert (25) and its parking (28), a tour (26), a concert on a game day (27), games (29, 30)
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, performer_ids) VALUES
  (21, 'Toronto Blue Jays at New York Yankees', at_(10, '13:05'), 'shown', 5725, 'Yankee Stadium', '{15533,15535}'),
  (22, 'Toronto Blue Jays at New York Yankees', at_(10, '19:05'), 'shown', 5725, 'Yankee Stadium', '{15533,15535}'),
  (23, 'Boston Red Sox at New York Yankees',    at_(11, '19:30'), 'shown', 5725, 'Yankee Stadium', '{15533,15532}'),
  (24, 'Boston Red Sox at New York Yankees',    at_(12, '12:00'), 'shown', 5725, 'Yankee Stadium', '{15533,15532}'),
  (25, 'Fall Out Boy',                          at_(20, '19:00'), 'shown', 5725, 'Yankee Stadium', NULL),
  (26, 'Yankee Stadium Tours',                  at_(21, '10:00'), 'shown', 5725, 'Yankee Stadium', NULL),
  (27, 'Zach Bryan',                            at_(13, '19:00'), 'shown', 5725, 'Yankee Stadium', NULL),
  (28, 'Parking: Fall Out Boy',                 at_(20, '19:00'), 'shown', 5725, 'Yankee Stadium', NULL),
  (29, 'Toronto Blue Jays at New York Yankees', at_(13, '19:05'), 'shown', 5725, 'Yankee Stadium', '{15533,15535}'),
  (30, 'Toronto Blue Jays at New York Yankees', at_(14, '19:05'), 'shown', 5725, 'Yankee Stadium', '{15533,15535}');

-- games: 101 holds the twin's listing (22 is game 102's minute); 103 is 25 minutes off; 104 sits on a noon placeholder;
-- 105 is a game day the concert 27 shares; 106 is removed and still tied to the hub row K900
INSERT INTO mlb_ticket_game (schedule_id, season, sport_id, game_type, game_date, game_time_local, game_time_utc, is_tbd, home_team_id, home_name, home_abbrev,
                             away_team_id, away_name, away_abbrev, venue_id, venue_name, venue_city, tevo_event_id, tevo_match_method, sg_event_id, removed_at) VALUES
  (101, 2027, 1, 'R', d(10), at_(10, '13:05')::timestamp, at_(10, '13:05')::timestamptz, false, 147, 'New York Yankees', 'NYY', 141, 'Toronto Blue Jays', 'TOR', 3313, 'Yankee Stadium', 'Bronx', 22, 'name_date', 601, NULL),
  (102, 2027, 1, 'R', d(10), at_(10, '19:05')::timestamp, at_(10, '19:05')::timestamptz, false, 147, 'New York Yankees', 'NYY', 141, 'Toronto Blue Jays', 'TOR', 3313, 'Yankee Stadium', 'Bronx', NULL, NULL, NULL, NULL),
  (103, 2027, 1, 'R', d(11), at_(11, '19:05')::timestamp, at_(11, '19:05')::timestamptz, false, 147, 'New York Yankees', 'NYY', 111, 'Boston Red Sox', 'BOS', 3313, 'Yankee Stadium', 'Bronx', 23, 'name_date', NULL, NULL),
  (104, 2027, 1, 'R', d(12), at_(12, '13:05')::timestamp, at_(12, '13:05')::timestamptz, false, 147, 'New York Yankees', 'NYY', 111, 'Boston Red Sox', 'BOS', 3313, 'Yankee Stadium', 'Bronx', 24, 'name_date', NULL, NULL),
  (105, 2027, 1, 'R', d(13), at_(13, '19:05')::timestamp, at_(13, '19:05')::timestamptz, false, 147, 'New York Yankees', 'NYY', 141, 'Toronto Blue Jays', 'TOR', 3313, 'Yankee Stadium', 'Bronx', 29, 'name_date', NULL, NULL),
  (106, 2027, 1, 'R', d(14), at_(14, '19:05')::timestamp, at_(14, '19:05')::timestamptz, false, 147, 'New York Yankees', 'NYY', 141, 'Toronto Blue Jays', 'TOR', 3313, 'Yankee Stadium', 'Bronx', 30, 'name_date', NULL, now());
INSERT INTO aq_event_map (aq_short_event_id, event_name, venue_name, event_date, aq_source, imported_at, tevo_event_id) VALUES
  ('K900', 'Toronto Blue Jays at New York Yankees', 'Yankee Stadium', at_(14, '19:05')::timestamp, 'system_seed', now() - interval '10 days', 30);
INSERT INTO mlb_hub_link (schedule_id, aq_short_event_id, tevo_event_id) VALUES (106, 'K900', 30);

-- stadium events: a concert (shares "fall", "boy" with listing 25), a party (no word in common with the tour), a concert on a game day
INSERT INTO mlb_ticket_event (schedule_id, team_id, sport_id, season, event_type, title, event_date, event_time_local, event_time_utc, is_tbd, venue_id, venue_name) VALUES
  (901, 147, 1, 2027, 'O', 'FALL OUT BOY: TWILIGHT OF THE PUNKS', d(20), at_(20, '19:00')::timestamp, at_(20, '19:00')::timestamptz, false, 3313, 'Yankee Stadium'),
  (902, 147, 1, 2027, 'O', 'Pre-Game Party June 1',              d(21), at_(21, '10:00')::timestamp, at_(21, '10:00')::timestamptz, false, 3313, 'Yankee Stadium'),
  (903, 147, 1, 2027, 'O', 'Zach Bryan',                         d(13), at_(13, '19:00')::timestamp, at_(13, '19:00')::timestamptz, false, 3313, 'Yankee Stadium');

-- SeatGeek: 601 is game 101's SeatGeek id (no EVO link of its own); 602 is nobody's game and carries its own link
INSERT INTO sg_events_canonical (sg_event_id, sg_event_name, sg_event_date, tevo_event_id, match_method) VALUES
  (601, 'Toronto Blue Jays at New York Yankees', d(10), NULL, NULL),
  (602, 'Boston Red Sox at New York Yankees',    d(11), 23, 'matcher_v3_pm24h');

\echo A identity before any pass: 601 answers through the schedule (game 101 as it stands), 602 through the SeatGeek link of its own, 999 nothing
SELECT * FROM event_mapper_identity('seatgeek', 601);
SELECT * FROM event_mapper_identity('sg', 602);
SELECT count(*) FROM event_mapper_identity('seatgeek', 999);

\echo B dry run: the twin dropped, one time flag, the removed game let go of the hub, no stadium event yet (no park known)
SELECT out_(mlb_ticket_map(false));
SELECT count(*) FROM mlb_map_audit;
SELECT count(*) FROM mlb_hub_link;

\echo C the pass
SELECT out_(mlb_ticket_map(true));
\echo C1 games: 101 dropped (twin), 102 took 22 by the minute, 103/104/105 stand, 106 keeps its EVO id
SELECT schedule_id, tevo_event_id, tevo_match_method, removed_at IS NOT NULL AS removed FROM mlb_ticket_game ORDER BY 1;
\echo C2 the audit: the twin, the flag (25 min), the removed link, the concert
SELECT action, target, schedule_id, regexp_replace(note, '\d{4}-\d\d-\d\d', 'D', 'g') FROM mlb_map_audit WHERE action IN ('drop', 'time_differs', 'hub_unlink', 'event_match') ORDER BY action, schedule_id;
\echo C3 stadium events: 901 matched through the park (learned from the games), 902 no word in common, 903 a game day
SELECT schedule_id, tevo_event_id, tevo_match_method FROM mlb_ticket_event ORDER BY 1;
SELECT mlb_venue_id, tevo_venue_id, games FROM mlb_venue_xref ORDER BY 1;
\echo C4 the hub: games and the concert each tied to a row; K900 free
SELECT l.entity, l.schedule_id, a.tevo_event_id, a.aq_source, a.event_name FROM mlb_hub_link l JOIN aq_event_map a ON a.aq_short_event_id = l.aq_short_event_id ORDER BY 1, 2;
SELECT aq_short_event_id, tevo_event_id FROM aq_event_map WHERE aq_short_event_id = 'K900';

\echo D the next pass: 101 takes the 13:05 listing by the minute; SeatGeek 601 follows; identity now answers 21; the flag is not written twice
SELECT out_(mlb_ticket_map(true));
SELECT schedule_id, tevo_event_id, tevo_match_method FROM mlb_ticket_game WHERE schedule_id IN (101, 102) ORDER BY 1;
SELECT sg_event_id, tevo_event_id, match_method FROM sg_events_canonical ORDER BY 1;
SELECT * FROM event_mapper_identity('seatgeek', 601);
SELECT action, count(*) FROM mlb_map_audit WHERE action IN ('time_differs', 'event_match', 'hub_unlink') GROUP BY 1 ORDER BY 1;

\echo E the removed game comes back: tied to the hub again on the next pass
UPDATE mlb_ticket_game SET removed_at = NULL WHERE schedule_id = 106;
SELECT out_(mlb_ticket_map(true));
SELECT l.entity, l.schedule_id, l.aq_short_event_id FROM mlb_hub_link l WHERE l.schedule_id = 106;

\echo F the title rule
SELECT mlb_stadium_title_fits('FALL OUT BOY: TWILIGHT OF THE PUNKS', 'Fall Out Boy'), mlb_stadium_title_fits('Pre-Game Party June 1', 'Yankee Stadium Tours'),
       mlb_stadium_title_fits('Suites: Slipnot', 'Slipknot'), mlb_stadium_title_fits('Zach Bryan', 'Zach Bryan: The Quittin Time Tour');

\echo G who may run what; the key of the link table
SELECT has_function_privilege('anon', 'mlb_stadium_title_fits(text,text)', 'EXECUTE'), has_function_privilege('service_role', 'mlb_ticket_map(boolean)', 'EXECUTE'),
       (SELECT command FROM cron.job WHERE jobname = 'mlb_ticket_map_hourly'),
       (SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conrelid = 'mlb_hub_link'::regclass AND c.contype = 'p');

\echo H the internal key in the resolver (mig 20261117171000): a SeatGeek id no mapper matched sits in a spine cluster another source tied to EVO 751 -> identity_spine; an ESPN game matched by espn_ticket_match -> identity_espn_game; the key-first form carries both; an unknown id answers nothing
INSERT INTO events (id, name, occurs_at_local, state, venue_id) VALUES (751, 'Spine Game', to_char(current_date + 20, 'YYYY-MM-DD') || 'T19:05:00', 'shown', 100);
INSERT INTO event_xmap (tevo_event_id, sg_event_id, vivid_event_id) VALUES (751, 7001, 8001);
INSERT INTO espn_ticket_game (espn_event_id, tevo_event_id) VALUES ('401900001', 751);
SELECT * FROM event_mapper_identity('seatgeek', 7001);
SELECT * FROM event_mapper_identity('espn', 401900001);
SELECT * FROM event_key_identity('sg', 7001);
SELECT * FROM event_key_identity('vivid', 8001);
SELECT count(*) FROM event_key_identity('seatgeek', 7777);
