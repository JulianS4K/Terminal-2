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

\echo I the internal event key (mig 20261117170000)
\echo I1 ESPN is the seventh source and seeds its bucket: a game at Capital One Arena (Vivid venue 77 paired to TEvo 500) with no EVO listing; Vivid 2201 and GoTickets 3201 attach by name; the game ESPN tied to EVO 401 joins that cluster by id
INSERT INTO vivid_catalog_venue (vivid_venue_id, name, city, state, country, tevo_venue_id, method) VALUES (77, 'Capital One Arena', 'Washington', 'DC', 'US', 500, 'name_state');
INSERT INTO espn_ticket_game (espn_event_id, espn_league, name, game_at_utc, time_valid, status, home_team_id, home_name, away_team_id, away_name, venue_name, venue_city, venue_state, vivid_production_id, vivid_venue_id, tevo_event_id) VALUES
  ('401909901', 'NHL', 'Boston Bruins at Washington Capitals', (ts_(15, '19:00') AT TIME ZONE 'America/New_York'), true, 'STATUS_SCHEDULED', '23', 'Washington Capitals', '1', 'Boston Bruins', 'Capital One Arena', 'Washington', 'DC', 2201, 77, NULL),
  ('401909902', 'NHL', 'Pittsburgh Penguins at Washington Capitals', (ts_(13, '19:00') AT TIME ZONE 'America/New_York'), true, 'STATUS_SCHEDULED', '23', 'Washington Capitals', '16', 'Pittsburgh Penguins', 'Capital One Arena', 'Washington', 'DC', NULL, 77, 401),
  ('401909903', 'NHL', 'TBD at Washington Capitals', (ts_(16, '19:00') AT TIME ZONE 'America/New_York'), true, 'STATUS_SCHEDULED', '23', 'Washington Capitals', '-1', 'TBD', 'Capital One Arena', 'Washington', 'DC', NULL, 77, NULL);
INSERT INTO vivid_catalog_event (vivid_event_id, name, event_local, event_date, vivid_venue_id, venue_country, performers) VALUES
  (2201, 'Boston Bruins at Washington Capitals', ts_(15, '19:00'), d(15), 77, 'US', '[{"name":"Washington Capitals"},{"name":"Boston Bruins"}]');
INSERT INTO gotickets_event (gt_event_id, name, performer, venue_name, venue_city, venue_state, event_time_utc, status, tevo_event_id) VALUES
  (3201, 'Boston Bruins at Washington Capitals', 'Washington Capitals', 'Capital One Arena', 'Washington', 'DC', (ts_(15, '19:00') AT TIME ZONE 'America/New_York'), 'AS_SCHEDULED', NULL);
SELECT (event_xmap_tick(45, true)) - 'run_id' - 'window' - 'ms' - 'rows_by_source' - 'rows' - 'rows_with_evo' - 'loose' - 'buckets' - 'clusters_in_window' - 'with_evo_and_others' - 'cross_mapped_without_evo' - 'merged' - 'evo_clusters_new' - 'evo_clusters_refreshed' - 'detached' - 'deleted_single' - 'attached_existing' - 'seed_candidates_by_source' - 'seeds_unjoined' - 'seed_candidates';
SELECT local_day - current_date AS day, seed_source, espn_event_id, tevo_event_id, vivid_event_id, gt_event_id, sources, methods FROM event_xmap WHERE espn_event_id IS NOT NULL ORDER BY local_day;
SELECT source, in_spine, with_evo, without_evo_but_cross_mapped FROM v_event_xmap_coverage WHERE source IN ('espn', 'vivid') ORDER BY 1;
SELECT internal_event_id = xmap_id AS key_is_the_row_id, espn_name, vivid_name, gotickets_name FROM v_event_xmap WHERE espn_event_id = 401909901;

\echo I2 the key is addressable by any source id, and the same key for every member
SELECT event_key_lookup('vivid', 2201) = event_key_lookup('espn', 401909901) AS same_key, event_key_lookup('gotickets', 3201) = event_key_lookup('espn', 401909901) AS same_key_gt,
       event_key_lookup('tevo', 401) = event_key_lookup('espn', 401909902) AS evo_game_same_key, event_key_lookup('vivid', 99999999) IS NULL AS unknown_is_null;

\echo I3 a merge retires a key into the survivor: the Vivid mapper maps 2201 to a new EVO listing of the Bruins game; the seed cluster folds into the EVO cluster; the old key still resolves
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_name) VALUES
  (402, 'Boston Bruins at Washington Capitals', at_(15, '19:00'), 'shown', 500, 'Capital One Arena', 'Washington, DC', 'Washington Capitals');
UPDATE vivid_catalog_event SET tevo_event_id = 402 WHERE vivid_event_id = 2201;
CREATE TEMP TABLE _old_key AS SELECT event_key_lookup('espn', 401909901) AS k;
SELECT (event_xmap_tick(45, true))->'merged';
SELECT (SELECT k FROM _old_key) <> event_key_lookup('espn', 401909901) AS key_changed,
       event_key_resolve((SELECT k FROM _old_key)) = event_key_lookup('espn', 401909901) AS old_key_resolves_to_survivor,
       event_key_resolve(event_key_lookup('espn', 401909901)) = event_key_lookup('espn', 401909901) AS live_key_resolves_to_itself,
       event_key_resolve(123456789) IS NULL AS unknown_key_is_null;
SELECT xmap_id = event_key_lookup('espn', 401909901) AS alias_points_at_survivor FROM event_xmap_alias WHERE old_xmap_id = (SELECT k FROM _old_key);
SELECT tevo_event_id, espn_event_id, vivid_event_id, gt_event_id, sources FROM event_xmap WHERE espn_event_id = 401909901;

\echo J Ticketmaster is the eighth source (mig 20261117190000): a TM event at Barclays Center (TM venue paired to TEvo 600) with a Vivid sibling and no EVO listing seeds the bucket; the Vivid row attaches by name; the key answers by the TM string id; the coverage view counts it
INSERT INTO vivid_catalog_venue (vivid_venue_id, name, city, state, country, tevo_venue_id, method) VALUES (78, 'Barclays Center', 'Brooklyn', 'NY', 'US', 600, 'name_state');
INSERT INTO tm_venue_xref VALUES ('KovZpZAEkn6A', 600);
INSERT INTO tm_discovery_event (tm_event_id, name, local_date, local_time, date_tbd, time_tba, status_code, tm_venue_id, venue_name, venue_city, venue_state, venue_country, attraction_names, is_product, tevo_event_id) VALUES
  ('G5diZ_o6tFFbV', 'Brooklyn Nets vs. Orlando Magic', d(20), '19:30', false, false, 'onsale', 'KovZpZAEkn6A', 'Barclays Center', 'Brooklyn', 'NY', 'US', ARRAY['Brooklyn Nets', 'Orlando Magic'], false, NULL),
  ('G5diZ_o6tFFbP', 'Nets Parking: Orlando Magic', d(20), '19:30', false, false, 'onsale', 'KovZpZAEkn6A', 'Barclays Center', 'Brooklyn', 'NY', 'US', NULL, true, NULL);
INSERT INTO vivid_catalog_event (vivid_event_id, name, event_local, event_date, vivid_venue_id, venue_country, performers) VALUES
  (2301, 'Orlando Magic at Brooklyn Nets', ts_(20, '19:30'), d(20), 78, 'US', '["Brooklyn Nets","Orlando Magic"]');
SELECT (event_xmap_tick(45, true))->'seeded_by_source';
SELECT seed_source, tm_event_id, ticketmaster_name, vivid_name, sources FROM v_event_xmap WHERE tm_event_id IS NOT NULL;
SELECT event_key_lookup_tm('G5diZ_o6tFFbV') = event_key_lookup('vivid', 2301) AS same_key, event_key_lookup_tm('G5diZ_o6tFFbP') IS NULL AS parking_never_enters;
SELECT source, in_spine, without_evo_but_cross_mapped FROM v_event_xmap_coverage WHERE source = 'ticketmaster';

\echo K the venue's primary box office (mig 20261123180000): two operator rows; the spine view names it beside the other sources' ids
SELECT tevo_venue_id, source, label FROM venue_primary_box_office ORDER BY 1;
INSERT INTO venue_primary_box_office (tevo_venue_id, source, label) VALUES (600, 'testbox', 'Test Box Office');
SELECT count(*) AS clusters_at_600, count(*) FILTER (WHERE primary_box_office = 'testbox') AS named_primary FROM v_event_xmap WHERE tevo_venue_id = 600;
SELECT count(*) FILTER (WHERE primary_box_office IS NULL) AS clusters_without_primary FROM v_event_xmap WHERE tevo_venue_id <> 600;
SELECT has_table_privilege('anon', 'venue_primary_box_office', 'SELECT'), has_table_privilege('service_role', 'venue_primary_box_office', 'SELECT');

\echo L the primary box office we poll is a source of the mapper and the spine (mig 20261123190000): a game maps by its two sides; a show maps as the one event of its day; a pass maps only to a pass; a series row is skipped; a row EVO lacks seeds its bucket with a Vivid sibling; the key answers by the box office id
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_name) VALUES
  (901, 'Memphis Grizzlies at Test Home Team', at_(12, '19:30'), 'shown', 600, 'Test Arena', 'Testville, NY', 'Test Home Team'),
  (902, 'Spring Series - Nashville SC at Test Home Club', at_(13, '14:00'), 'shown', 600, 'Test Arena', 'Testville, NY', 'Test Home Club'),
  (903, 'Rugby Sevens', at_(14, '00:00'), 'shown', 600, 'Test Arena', 'Testville, NY', 'Rugby Sevens'),
  (904, 'Rugby Sevens - 2 Day Pass', at_(14, '00:00'), 'shown', 600, 'Test Arena', 'Testville, NY', 'Rugby Sevens'),
  (905, 'Parking: Rugby Sevens', at_(14, '00:00'), 'shown', 600, 'Test Arena', 'Testville, NY', NULL);
INSERT INTO primary_poll_event (source, source_event_id, name, event_date, start_local_time, venue_name, venue_city, venue_state) VALUES
  ('testbox', '1001', 'Test Home Team vs. Grizzlies', d(12), '19:30', 'Test Arena', 'Testville', 'NY'),
  ('testbox', '1002', 'Test Home Club vs. Nashville SC', d(13), '14:00', 'Test Arena', 'Testville', 'NY'),
  ('testbox', '1003', 'Rugby Sevens - Saturday', d(14), '11:00', 'Test Arena', 'Testville', 'NY'),
  ('testbox', '1004', 'Rugby Sevens - 2 Day Pass', d(14), '11:00', 'Test Arena', 'Testville', 'NY'),
  ('testbox', '1005', 'DecemberSeries 2026', d(15), '10:00', 'Test Arena', 'Testville', 'NY'),
  ('testbox', '1006', 'Test Home Team vs. Nobody', d(16), '19:00', 'Test Arena', 'Testville', 'NY');
INSERT INTO vivid_catalog_event (vivid_event_id, name, event_local, event_date, vivid_venue_id) VALUES (99006, 'Test Home Team vs Nobody', at_(16, '19:00')::timestamp, d(16), 78);
SELECT primary_poll_map(true) - 'run_id' - 'sample';
SELECT source_event_id, tevo_event_id, tevo_match_method FROM primary_poll_event ORDER BY source_event_id;
SELECT action, source_event_id, tevo_event_id, method FROM primary_poll_map_audit ORDER BY source_event_id;
\echo L1 a second run writes nothing; a match whose EVO event is ignored is dropped
SELECT (primary_poll_map(true) - 'run_id' - 'sample')->'written', (primary_poll_map(true) - 'run_id' - 'sample')->'already_matched';
UPDATE events SET state = 'ignored' WHERE id = 902;
SELECT (primary_poll_map(true) - 'run_id' - 'sample') - 'candidates';
SELECT source_event_id, tevo_event_id FROM primary_poll_event WHERE source_event_id = '1002';
\echo L2 the spine: the matched rows join their EVO clusters; the row EVO lacks seeds a cluster with its Vivid sibling; the key answers by the box office id
SELECT (event_xmap_tick(45, true) - 'run_id' - 'ms' - 'window')->'rows_by_source'->'primary' AS primary_rows, (event_xmap_tick(45, true))->'seeded_by_source';
SELECT x.pp_event_seq IS NOT NULL AS has_primary, x.tevo_event_id, x.vivid_event_id, x.sources, v.primary_event_id, v.primary_name, v.primary_box_office
  FROM event_xmap x JOIN v_event_xmap v ON v.xmap_id = x.xmap_id WHERE x.pp_event_seq IS NOT NULL ORDER BY x.local_day;
SELECT event_key_lookup_primary('testbox', '1006') = (SELECT xmap_id FROM event_xmap WHERE vivid_event_id = 99006) AS key_by_box_office_id,
       event_key_lookup('primary', (SELECT pp_seq FROM primary_poll_event WHERE source_event_id = '1001')) = (SELECT xmap_id FROM event_xmap WHERE tevo_event_id = 901) AS key_by_seq;
SELECT source, in_spine FROM v_event_xmap_coverage WHERE source = 'primary';
SELECT jobname, schedule FROM cron.job WHERE jobname = 'primary_poll_map_hourly';

\echo M a member whose spine row is outside the window (mig 20261124010000): a TM show at Barclays Center sat on a day before the window with a Vivid sibling; TM reschedules it to day 21, where a Vivid + TickPick cluster of the show already exists. The pass used to break on the one-row-per-source-id key; now the id leaves the old row (audited day_moved) and joins the cluster of the new day; the old row keeps its Vivid member
INSERT INTO tickpick_catalog_venue (tp_venue_id, name, city, state, country, tevo_venue_id, method) VALUES (19, 'Barclays Center', 'Brooklyn', 'NY', 'US', 600, 'name_state');
INSERT INTO tm_discovery_event (tm_event_id, name, local_date, local_time, date_tbd, time_tba, status_code, tm_venue_id, venue_name, venue_city, venue_state, venue_country, attraction_names, is_product, tevo_event_id) VALUES
  ('Z7r9jZ1TEST1', 'CupcakKe (Ages 16 & Over)', d(-10), '20:00', false, false, 'onsale', 'KovZpZAEkn6A', 'Barclays Center', 'Brooklyn', 'NY', 'US', ARRAY['CupcakKe'], false, NULL);
INSERT INTO vivid_catalog_event (vivid_event_id, name, event_local, event_date, vivid_venue_id, venue_country, performers) VALUES
  (2302, 'CupcakKe', ts_(-10, '20:00'), d(-10), 78, 'US', '["CupcakKe"]'),
  (2303, 'CupcakKe', ts_(21, '20:00'), d(21), 78, 'US', '["CupcakKe"]');
INSERT INTO tickpick_catalog_event (tp_event_id, name, status, event_local, event_date, date_confirmed, tp_venue_id, venue_country, performers, tevo_event_id) VALUES
  (1013, 'CupcakKe', 'active', ts_(21, '20:00'), d(21), true, 19, 'US', '[{"name":"CupcakKe"}]', NULL);
-- the past cluster, as an earlier pass left it: TM + Vivid on day -10, no EVO listing
INSERT INTO event_xmap (venue_key, local_day, tevo_venue_id, venue_name, name, start_local, seed_source, tm_event_seq, vivid_event_id, methods)
  VALUES ('tv:600', d(-10), 600, 'Barclays Center', 'CupcakKe (Ages 16 & Over)', ts_(-10, '20:00')::timestamp, 'tm', (SELECT tm_seq FROM tm_discovery_event WHERE tm_event_id = 'Z7r9jZ1TEST1'), 2302, '{"tm": "tm", "vivid": "name"}');
SELECT (event_xmap_tick(45, true))->'seeded_by_source' AS day21_cluster_forms;
UPDATE tm_discovery_event SET local_date = d(21), status_code = 'rescheduled' WHERE tm_event_id = 'Z7r9jZ1TEST1';
SELECT (event_xmap_tick(45, true) - 'run_id' - 'ms' - 'window')->'detached' AS detached;
SELECT local_day - current_date AS day, tm_event_seq IS NOT NULL AS has_tm, vivid_event_id, tp_event_id, sources FROM event_xmap WHERE vivid_event_id IN (2302, 2303) ORDER BY local_day;
SELECT a.action, a.source, a.note, x.local_day - current_date AS day FROM event_xmap_audit a JOIN event_xmap x ON x.xmap_id = a.xmap_id
 WHERE a.source = 'tm' AND a.source_id = (SELECT tm_seq FROM tm_discovery_event WHERE tm_event_id = 'Z7r9jZ1TEST1') ORDER BY a.id;
SELECT event_key_lookup_tm('Z7r9jZ1TEST1') = event_key_lookup('vivid', 2303) AS key_follows_the_show;
