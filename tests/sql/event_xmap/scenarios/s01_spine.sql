\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- The cross-source spine (mig 20261117130000): EVO-keyed clusters, name pairing within a venue + day, seeds where
-- two sources meet without EVO, the minute tiebreak, abstention on ambiguity, moves when a catalogue mapper finds
-- the EVO id, detaches when a day moves, single-source seeds deleted, and the two views.
CREATE FUNCTION d(n int) RETURNS date LANGUAGE sql AS $$ SELECT current_date + n $$;
CREATE FUNCTION at_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') || 'T' || hm || ':00' $$;
CREATE FUNCTION ts_(n int, hm text) RETURNS timestamp LANGUAGE sql AS $$ SELECT at_(n, hm)::timestamp $$;
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$ SELECT (j - 'run_id' - 'window' - 'ms')::text $$;

-- the TEvo mirror: venue 100 (Yankee Stadium, New York NY, Eastern) and 300 (Kennedy Center, Washington DC)
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_name) VALUES
  (201, 'Boston Red Sox at New York Yankees', at_(5, '19:05'), 'shown', 100, 'Yankee Stadium', 'Bronx, NY', 'New York Yankees'),
  (301, 'Hamilton', at_(6, '19:30'), 'shown', 300, 'Kennedy Center Opera House', 'Washington, DC', 'Hamilton');
INSERT INTO venue_timezone VALUES (100, 'America/New_York', 'Yankee Stadium'), (300, 'America/New_York', 'Kennedy Center Opera House');

-- venues on the catalogues: 11/21 paired to 100; 12/22 paired to 300; 13 (TickPick) and 23 (Vivid) are "Field of Dreams, IA" — no TEvo venue
INSERT INTO tickpick_catalog_venue (tp_venue_id, name, city, state, country, tevo_venue_id, method) VALUES
  (11, 'Yankee Stadium', 'Bronx', 'NY', 'US', 100, 'name_state'), (12, 'Kennedy Center Opera House', 'Washington', 'DC', 'US', 300, 'name_state'),
  (13, 'Field of Dreams', 'Dyersville', 'IA', 'US', NULL, NULL);
INSERT INTO vivid_catalog_venue (vivid_venue_id, name, city, state, country, tevo_venue_id, method) VALUES
  (21, 'Yankee Stadium', 'Bronx', 'NY', 'US', 100, 'name_state'), (22, 'Kennedy Center Opera House', 'Washington', 'DC', 'US', 300, 'name_state'),
  (23, 'Field Of Dreams', 'Dyersville', 'IA', 'US', NULL, NULL);
INSERT INTO mlb_venue_xref VALUES (3313, 100), (9999, 100);

-- day 5, Yankee Stadium: the game EVO lists (201) — TickPick and Vivid mapped to it by their mappers, GoTickets not yet; MLB game 9001 mapped too
INSERT INTO mlb_ticket_game (schedule_id, game_date, game_time_local, is_tbd, venue_id, venue_name, venue_city, home_name, away_name, tevo_event_id) VALUES
  (9001, d(5), ts_(5, '19:05'), false, 3313, 'Yankee Stadium', 'Bronx', 'New York Yankees', 'Boston Red Sox', 201),
  -- day 7: a 2027-style game EVO does not list yet; TickPick and GoTickets list it
  (9002, d(7), ts_(7, '13:05'), false, 3313, 'Yankee Stadium', 'Bronx', 'New York Yankees', 'Toronto Blue Jays', NULL),
  (9003, d(7), ts_(7, '19:05'), false, 3313, 'Yankee Stadium', 'Bronx', 'New York Yankees', 'Toronto Blue Jays', NULL);   -- a doubleheader
INSERT INTO tickpick_catalog_event (tp_event_id, name, status, event_local, event_date, time_confirmed, tp_venue_id, venue_country, performers, tevo_event_id) VALUES
  (1001, 'New York Yankees vs. Boston Red Sox', 'active', ts_(5, '19:05'), d(5), true, 11, 'US', '[{"name":"New York Yankees"},{"name":"Boston Red Sox"}]', 201),
  (1002, 'New York Yankees vs. Toronto Blue Jays', 'active', ts_(7, '13:05'), d(7), true, 11, 'US', '[{"name":"New York Yankees"},{"name":"Toronto Blue Jays"}]', NULL),
  (1003, 'New York Yankees vs. Toronto Blue Jays', 'active', ts_(7, '19:05'), d(7), true, 11, 'US', '[{"name":"New York Yankees"},{"name":"Toronto Blue Jays"}]', NULL),
  (1004, 'Hamilton', 'active', ts_(6, '19:30'), d(6), true, 12, 'US', '[{"name":"Hamilton"}]', 301),
  (1005, 'Field of Dreams Game: Cubs vs. Cardinals', 'active', ts_(9, '19:15'), d(9), true, 13, 'US', '[{"name":"Chicago Cubs"},{"name":"St. Louis Cardinals"}]', NULL),
  (1006, 'Comedy Jam', 'active', ts_(8, '20:00'), d(8), true, 12, 'US', '[{"name":"Comedy Jam"}]', NULL);                -- alone on its day: no second source
INSERT INTO vivid_catalog_event (vivid_event_id, name, event_local, event_date, time_known, vivid_venue_id, venue_country, performers, tevo_event_id) VALUES
  (2001, 'Boston Red Sox at New York Yankees', ts_(5, '19:05'), d(5), true, 21, 'US', '["Boston Red Sox","New York Yankees"]', 201),
  (2002, 'Toronto Blue Jays at New York Yankees', ts_(7, '00:00'), d(7), false, 21, 'US', '["Toronto Blue Jays","New York Yankees"]', NULL),   -- time unknown: two games fit -> abstains
  (2004, 'Hamilton', ts_(6, '19:30'), d(6), true, 22, 'US', '["Hamilton"]', NULL),                                                      -- not mapped by its mapper (say the venue paired late)
  (2005, 'Chicago Cubs at St. Louis Cardinals - Field of Dreams Game', ts_(9, '19:15'), d(9), true, 23, 'US', '["Chicago Cubs","St. Louis Cardinals"]', NULL);
-- GoTickets: UTC only; 23:59 local = unknown time; venue by name + state
INSERT INTO gotickets_event (gt_event_id, name, performer, venue_name, venue_city, venue_state, event_time_utc, status, tevo_event_id) VALUES
  (3001, 'Boston Red Sox at New York Yankees', 'New York Yankees', 'Yankee Stadium', 'Bronx', 'NY', (ts_(5, '19:05') AT TIME ZONE 'America/New_York'), 'AS_SCHEDULED', NULL),
  (3002, 'Toronto Blue Jays at New York Yankees', 'New York Yankees', 'Yankee Stadium', 'Bronx', 'NY', (ts_(7, '13:05') AT TIME ZONE 'America/New_York'), 'AS_SCHEDULED', NULL),
  (3003, 'Toronto Blue Jays at New York Yankees', 'New York Yankees', 'Yankee Stadium', 'Bronx', 'NY', (ts_(7, '23:59') AT TIME ZONE 'America/New_York'), 'AS_SCHEDULED', NULL),
  (3004, 'Hamilton', 'Hamilton', 'Kennedy Center Opera House', 'Washington', 'DC', (ts_(6, '19:30') AT TIME ZONE 'America/New_York'), 'AS_SCHEDULED', NULL),
  (3005, 'Hamilton', 'Hamilton', 'Kennedy Center Opera House', 'Washington', 'DC', (ts_(6, '19:30') AT TIME ZONE 'America/New_York'), 'CANCELLED', NULL),
  (3006, 'Parking: Boston Red Sox at New York Yankees', 'New York Yankees', 'Yankee Stadium', 'Bronx', 'NY', (ts_(5, '19:05') AT TIME ZONE 'America/New_York'), 'AS_SCHEDULED', NULL);
-- AXS: a concert at the Kennedy Center on day 6 too — a different show, different name: stays apart
INSERT INTO axs_export_event (axs_event_id, event_title, event_title_clean, headliner, performers, venue_name, venue_city, venue_state, venue_country, event_date_local, is_tba, tevo_venue_id) VALUES
  (4001, 'Hamilton - An American Musical', 'Hamilton', 'Hamilton', ARRAY['Hamilton'], 'Kennedy Center Opera House', 'Washington', 'DC', 'US', at_(6, '19:30'), false, 300),
  (4002, 'NSO Pops: Holiday Concert', 'NSO Pops Holiday Concert', 'National Symphony Orchestra', ARRAY['National Symphony Orchestra'], 'Kennedy Center Opera House', 'Washington', 'DC', 'US', at_(6, '20:00'), false, 300);

\echo A dry run: the working set, nothing written
SELECT out_(event_xmap_tick(45, false));
SELECT count(*) FROM event_xmap;

\echo B the pass
SELECT out_(event_xmap_tick(45, true));
\echo B1 day 5: one EVO-keyed cluster with the game from five sources (EVO, MLB, TickPick, Vivid, GoTickets by name); the GoTickets parking row is nowhere
SELECT local_day - current_date AS day, name, tevo_event_id, mlb_schedule_id, tp_event_id, vivid_event_id, gt_event_id, axs_event_id, sources, methods FROM event_xmap ORDER BY local_day, start_local, xmap_id;
\echo B2 day 7: no EVO — the two MLB games seed, TickPick and GoTickets attach by the minute; Vivid (time unknown) abstains; GoTickets 23:59 (unknown) abstains
SELECT count(*) AS clusters_without_evo FROM event_xmap WHERE tevo_event_id IS NULL;
SELECT action, source, count(*) FROM event_xmap_audit GROUP BY 1, 2 ORDER BY 1, 2;
\echo B3 day 9, Field of Dreams (no TEvo venue): TickPick and Vivid meet on name + state, the game read as two sides
SELECT venue_key, name, tp_event_id, vivid_event_id, sources FROM event_xmap WHERE venue_key LIKE 'ns:%';
\echo B4 day 8: Comedy Jam alone — no cluster; the AXS NSO concert stays apart from Hamilton
SELECT count(*) FROM event_xmap WHERE tp_event_id = 1006 OR gt_event_id = 3006;
SELECT axs_event_id, name FROM event_xmap WHERE axs_event_id IS NOT NULL ORDER BY 1;

\echo C a second pass changes nothing
SELECT out_(event_xmap_tick(45, true)) ;
SELECT count(*) FROM event_xmap_audit;

\echo D the Vivid mapper later maps 2002 to a new EVO listing of the 13:05 game, and the MLB mapper the game: the EVO cluster forms, and the seed cluster (TickPick + GoTickets) merges into it
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_name) VALUES
  (202, 'Toronto Blue Jays at New York Yankees', at_(7, '13:05'), 'shown', 100, 'Yankee Stadium', 'Bronx, NY', 'New York Yankees');
UPDATE vivid_catalog_event SET tevo_event_id = 202 WHERE vivid_event_id = 2002;
UPDATE mlb_ticket_game SET tevo_event_id = 202 WHERE schedule_id = 9002;
SELECT out_(event_xmap_tick(45, true));
SELECT local_day - current_date AS day, name, tevo_event_id, mlb_schedule_id, tp_event_id, vivid_event_id, gt_event_id, sources, methods FROM event_xmap WHERE local_day = d(7) ORDER BY start_local, xmap_id;

\echo E the day moves for TickPick 1003: it is detached, re-seeds nothing (alone on day 10), and the 19:05 cluster keeps MLB + GoTickets
UPDATE tickpick_catalog_event SET event_date = d(10), event_local = ts_(10, '19:05') WHERE tp_event_id = 1003;
SELECT out_(event_xmap_tick(45, true));
SELECT local_day - current_date AS day, name, mlb_schedule_id, tp_event_id, gt_event_id, sources FROM event_xmap WHERE mlb_schedule_id = 9003;
SELECT action, source, source_id, note FROM event_xmap_audit WHERE action IN ('detach', 'delete', 'move') ORDER BY id;

\echo F the views
SELECT source, in_spine, with_evo, without_evo_but_cross_mapped, in_three_or_more_sources FROM v_event_xmap_coverage ORDER BY 1;
SELECT name, evo_name, tickpick_name, vivid_name, gotickets_name, mlb_name FROM v_event_xmap ORDER BY local_day, start_local, xmap_id;

\echo G who may run what; the crons
SELECT has_function_privilege('anon', 'event_xmap_tick(integer,boolean)', 'EXECUTE'), has_function_privilege('service_role', 'event_xmap_tick(integer,boolean)', 'EXECUTE'), has_table_privilege('anon', 'event_xmap', 'SELECT');
SELECT jobname, schedule FROM cron.job WHERE jobname LIKE 'event_xmap%' ORDER BY 1;

\echo H steady state (mig 20261117150000)
\echo H1 a GoTickets row the mapper tied to EVO 401 keys its venue by name ("Capital One Arena - DC" is not a TEvo venue name): it sits in the EVO cluster and two passes later it is still there, nothing detached
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_name) VALUES
  (401, 'Washington Capitals vs Pittsburgh Penguins', at_(12, '19:00'), 'shown', 500, 'Capital One Arena', 'Washington, DC', 'Washington Capitals');
INSERT INTO gotickets_event (gt_event_id, name, performer, venue_name, venue_city, venue_state, event_time_utc, status, tevo_event_id) VALUES
  (3105, 'Pittsburgh Penguins at Washington Capitals', 'Washington Capitals', 'Capital One Arena - DC', 'Washington', 'DC', (ts_(12, '19:00') AT TIME ZONE 'America/New_York'), 'AS_SCHEDULED', 401);
SELECT (event_xmap_tick(45, true))->'detached';
SELECT (event_xmap_tick(45, true))->'detached';
SELECT local_day - current_date AS day, venue_key, tevo_event_id, gt_event_id, methods FROM event_xmap WHERE tevo_event_id = 401;
SELECT count(*) AS detach_rows_for_3105 FROM event_xmap_audit WHERE action = 'detach' AND source = 'gotickets' AND source_id = 3105;

\echo H2 two sources on one day at Yankee Stadium whose names do not fit: a seed candidate, no cluster written, no delete — and no audit rows for it
INSERT INTO tickpick_catalog_event (tp_event_id, name, status, event_local, event_date, tp_venue_id, venue_country, performers) VALUES
  (1009, 'Monster Jam', 'active', ts_(14, '19:00'), d(14), 11, 'US', '[{"name":"Monster Jam"}]');
INSERT INTO vivid_catalog_event (vivid_event_id, name, event_local, event_date, vivid_venue_id, venue_country, performers) VALUES
  (2009, 'Garth Brooks', ts_(14, '19:30'), d(14), 21, 'US', '["Garth Brooks"]');
SELECT (event_xmap_tick(45, true)) - 'run_id' - 'window' - 'ms' - 'rows' - 'rows_by_source' - 'rows_with_evo' - 'loose' - 'buckets' - 'clusters_in_window' - 'with_evo_and_others' - 'cross_mapped_without_evo' - 'attached_existing' - 'merged' - 'evo_clusters_new' - 'evo_clusters_refreshed' - 'detached' - 'seed_candidates_by_source' - 'seeded_by_source';
SELECT count(*) AS clusters_on_day_14 FROM event_xmap WHERE local_day = d(14);
SELECT count(*) AS audit_rows_for_them FROM event_xmap_audit WHERE (source = 'tickpick' AND source_id = 1009) OR (source = 'vivid' AND source_id = 2009);

\echo H3 EVO 401 is rescheduled to day 13: the cluster follows its EVO event; the GoTickets member (own day still 12) stays, by its id
UPDATE events SET occurs_at_local = at_(13, '19:00') WHERE id = 401;
SELECT (event_xmap_tick(45, true))->'evo_clusters_refreshed', (event_xmap_tick(45, true))->'detached';
SELECT local_day - current_date AS day, tevo_event_id, gt_event_id FROM event_xmap WHERE tevo_event_id = 401;
