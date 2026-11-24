-- The mapper front doors: every source through one call per mapper; the venue sync and the performer derive, rule by rule.
-- Dates are relative to today so the coverage rows are stable.
\set QUIET 1
\pset footer off
\pset format aligned
SET client_min_messages = warning;
SET timezone = 'UTC';

CREATE FUNCTION d(n int) RETURNS date LANGUAGE sql AS $$ SELECT current_date + n $$;
CREATE FUNCTION err_(q text) RETURNS text LANGUAGE plpgsql AS $$ BEGIN EXECUTE q; RETURN 'no error'; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $$;
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$ SELECT jsonb_pretty(j - 'run_id') $$;

-- ───────── the EVO mirror ─────────
INSERT INTO public.performer_metadata VALUES (11, 'Billy Joel'), (12, 'New York Knicks'), (13, 'Boston Celtics'), (14, 'U2'),
                                             (15, 'Hamilton'), (16, 'Swan Lake'), (17, 'Phish'), (18, 'Los Angeles Lakers');
INSERT INTO public.events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_id, primary_performer_name, performer_ids, last_seen) VALUES
  (1, 'Billy Joel',                        '2027-03-01T20:00:00', 'shown', 100, 'Madison Square Garden',   'New York, NY', 11, 'Billy Joel',      '{11}',     now()),
  (2, 'Boston Celtics at New York Knicks', '2027-03-05T19:30:00', 'shown', 100, 'Madison Square Garden',   'New York, NY', 12, 'New York Knicks', '{12,13}',  now()),
  (3, 'Los Angeles Lakers at New York Knicks','2027-03-09T19:30:00','shown',100, 'Madison Square Garden',  'New York, NY', 12, 'New York Knicks', '{12,18}',  now()),
  (4, 'Hamilton',                          '2027-03-07T14:00:00', 'shown', 300, 'Richard Rodgers Theatre', 'New York, NY', 15, 'Hamilton',        '{15}',     now()),
  (5, 'U2',                                '2027-04-01T20:00:00', 'shown', 400, 'Sphere',                  'Las Vegas, NV', 14, 'U2',             '{14}',     now()),
  (6, 'Swan Lake',                         '2027-04-02T19:00:00', 'shown', 500, 'Palace Theatre',          'Albany, NY',    16, 'Swan Lake',      '{16}',     now()),
  (7, 'Phish',                             '2027-04-03T19:00:00', 'shown', 600, 'Palace Theatre',          'Syracuse, NY',  17, 'Phish',          '{17}',     now()),
  (8, 'Phish',                             '2027-04-04T19:00:00', 'shown', 700, 'The Anthem',              'Washington, DC',17, 'Phish',          '{17}',     now()),
  (9, 'Phish',                             '2027-04-05T19:00:00', 'shown', 800, 'Capital One Arena',       'Washington, DC',17, 'Phish',          '{17}',     now()),
  (10,'Phish',                             '2027-04-06T19:00:00', 'shown', 900, 'Echo Lounge',             'Dallas, TX',    17, 'Phish',          '{17}',     now()),
  (11,'Phish',                             '2027-04-07T19:00:00', 'shown', 950, 'Solo Hall',               'Austin, TX',    17, 'Phish',          '{17}',     now());

-- ───────── the hub and the venue map the shared resolver reads (one venue so far) ─────────
INSERT INTO public.aq_event_map (aq_short_event_id, event_name, event_date, aq_source, tevo_event_id, sg_event_id, sh_event_id, sd_event_id, vivid_event_id, tp_event_id) VALUES
  ('AAAAAA1', 'Billy Joel', '2027-03-01 20:00', 'aq_curated', 1, 5001, 6001, 6501, 7001, 9001),
  ('AAAAAA2', 'Celtics at Knicks', '2027-03-05 19:30', 'aq_curated', 2, NULL, 6002, NULL, NULL, 9999);
INSERT INTO public.cross_source_venue_map (tevo_venue_id, tevo_venue_name, tevo_venue_location, city, state, country, tickpick_aliases) VALUES
  (100, 'Madison Square Garden', 'New York, NY', 'New York', 'NY', 'US', '["MSG"]');
INSERT INTO public.aq_venue_map (venue_short_id, venue_name, city, state, tevo_venue_id, sg_venue_id, tickpick_venue_id) VALUES
  ('VMSG001', 'Madison Square Garden', 'New York', 'NY', 100, 31, 1),
  ('VRR0001', 'Richard Rodgers Theatre', 'New York', 'NY', 300, 32, 77);   -- TickPick 77: the catalogue says venue 300 too? no — see below

-- ───────── the catalogues ─────────
INSERT INTO public.tickpick_catalog_venue VALUES
  (1,  'Madison Square Garden',        'New York',   'NY', 100, 'aq_venue_map'),
  (2,  'Rodgers Theatre',              'New York',   'NY', 300, 'pair_eq_city'),      -- strong: a new row, and "Rodgers Theatre" an alias
  (3,  'Sphere at The Venetian',       'Las Vegas',  'NV', 400, 'pair_affix'),        -- weak: earns the row with GoTickets' help, its name is no alias
  (4,  'Palace Theatre',               'Albany',     'NY', 500, 'name_state'),        -- two Palace Theatres in NY: a name cannot tell them apart
  (5,  'Palace Theatre',               'Syracuse',   'NY', 600, 'pair_eq_city'),
  (6,  'The Anthem Parking',           'Washington', 'DC', 700, 'pair_eq_city'),      -- parking: never
  (7,  'Anthem DC',                    'Washington', 'DC', 700, 'pair_cooccur'),      -- weak… (and so no alias, no id)
  (8,  'Capital One Arena',            'Washington', 'DC', 800, 'name_state'),
  (9,  'Nowhere Hall',                 'Reno',       'NV', NULL, NULL),
  (10, 'Echo Lounge Dallas',           'Dallas',     'TX', 900, 'pair_cooccur'),      -- weak; venue 900 stands on GoTickets' strong pairing
  (11, 'Solo Weak Hall',               'Austin',     'TX', 950, 'pair_affix'),        -- weak and alone: waits for a second source
  (77, 'Richard Rodgers Theatre NYC',  'New York',   'NY', 301, 'name_state');        -- TickPick 77: the hub's venue map says 300, the catalogue 301
INSERT INTO public.vivid_catalog_venue VALUES
  (21, 'Madison Square Garden - New York, NY', 'New York',   'NY', 100, 'pair_eq_city'),
  (22, 'The Anthem',                           'Washington', 'DC', 700, 'pair_affix'),   -- …weak, but the second source for venue 700
  (23, 'Capital One Arena',                    'Washington', 'DC', 800, 'pair_eq_city'),
  (24, 'Arena DC',                             'Washington', 'DC', 800, 'pair_sibling'),
  (25, 'Arena DC',                             'Washington', 'DC', 700, 'pair_cooccur'), -- "Arena DC" points two ways in DC: not an alias
  (26, 'Madison Square Garden Parking',        'New York',   'NY', 100, 'pair_parking');
INSERT INTO public.evo_gt_venue_link VALUES
  (900, 'echolounge|dallas|TX', 'Echo Lounge & Music Hall', 'Dallas', 'TX', 'crosswalk_alias'),
  (400, 'sphere|lasvegas|NV',   'Sphere',                   'Las Vegas', 'NV', 'city_name_similarity');   -- the second source for venue 400
INSERT INTO public.mlb_venue_xref VALUES (3289, 'Citi Field', 'Flushing', 1000, 'name');   -- no EVO event at venue 1000: no name to give the row
INSERT INTO public.axs_export_event (axs_event_id, event_title, event_date_local, venue_id, venue_name, venue_city, venue_state, last_seen_utc, tevo_event_id, tevo_venue_id, match_method) VALUES
  (4001, 'Billy Joel', to_char(d(40), 'YYYY-MM-DD') || 'T20:00:00', 555, 'Madison Square Garden', 'New York', 'NY', now(), 1, 100, 'venue_date_time'),
  (4002, 'Some Show',  to_char(d(41), 'YYYY-MM-DD') || 'T20:00:00', 555, 'Madison Square Garden', 'New York', 'NY', now(), NULL, 100, NULL);

INSERT INTO public.tickpick_catalog_event VALUES
  (9001, 'Billy Joel',                  d(40), '[{"performer_id":"501","name":"Billy Joel","role":"Headliner"}]', now(), 1, 'hub_identity'),
  (9002, 'Knicks vs Celtics',           d(44), '[{"performer_id":"502","name":"New York Knicks","role":"Home Team"},{"performer_id":"503","name":"Boston Celtics","role":"Away Team"}]', now(), 2, 'venue_day_name'),
  (9003, 'Knicks vs Lakers',            d(48), '[{"performer_id":"502","name":"New York Knicks","role":"Home Team"},{"performer_id":"504","name":"LA Lakers","role":"Away Team"}]', now(), 3, 'venue_day_name'),
  (9004, 'Hamilton (NY)',               d(46), '[{"performer_id":"505","name":"Hamilton - The Musical","role":"Headliner"}]', now(), 4, 'venue_day_name'),
  (9005, 'U2',                          d(70), '[{"performer_id":"506","name":"U2","role":"Headliner"}]', now(), 5, 'venue_day_name'),
  (9006, 'World Ballet: Swan Lake',     d(71), '[{"performer_id":"507","name":"World Ballet Company","role":"Featured"},{"performer_id":"508","name":"Swan Lake","role":"Headliner"}]', now(), 6, 'venue_day_name'),
  (9007, 'Phish',                       d(72), '[{"performer_id":"509","name":"Phish","role":"Headliner"}]', now(), 7, 'venue_day_name'),
  (9008, 'Phish',                       d(73), '[{"performer_id":"509","name":"Phish","role":"Headliner"}]', now(), 8, 'venue_day_name'),
  (9009, 'A Tribute Night',             d(74), '[{"performer_id":"510","name":"Totally Different Act","role":"Headliner"}]', now(), 9, 'venue_day_name'),
  (9010, 'Split Act',                   d(75), '[{"performer_id":"511","name":"Phish Tribute","role":"Headliner"}]', now(), 10, 'venue_day_name'),
  (9011, 'Split Act',                   d(76), '[{"performer_id":"511","name":"Phish Tribute","role":"Headliner"}]', now(), 1, 'venue_day_name'),
  (9014, 'Billy Joel',                  d(40), '[{"performer_id":"501","name":"Billy Joel","role":"Headliner"},{"performer_id":"512","name":"Billy Joel Parking","role":"Featured"}]', now(), 1, 'hub_identity'),
  (9015, 'Bill C Elvis Night',          d(78), '[{"performer_id":"513","name":"Hamilton","role":"Featured"},{"performer_id":"514","name":"Hamil","role":"Headliner"}]', now(), 4, 'venue_day_name'),
  (9016, 'An Evening of Swan',          d(79), '[{"performer_id":"516","name":"Swan","role":"Headliner"}]', now(), 6, 'venue_day_name'),
  (9012, 'Unmapped Show',               d(77), '[{"performer_id":"599","name":"Nobody Yet","role":"Headliner"}]', now(), NULL, NULL),
  (9013, 'Old Show',                    d(-5), '[]', now(), NULL, NULL);
INSERT INTO public.vivid_catalog_event VALUES
  (7001, 'Billy Joel',                  d(40), '[{"performerId":801,"name":"Billy Joel","master":true}]', now(), 1, 'hub_identity'),
  (7002, 'Boston Celtics at New York Knicks', d(44), '[{"performerId":802,"name":"New York Knicks","master":true},{"performerId":803,"name":"Boston Celtics","master":false}]', now(), 2, 'venue_time_name'),
  (7003, 'Billy Joel Night',            d(50), '[{"performerId":899,"name":"Billy Joel","master":true}]', now(), 1, 'venue_day_name'),   -- a second Vivid id wanting Billy Joel
  (7004, 'Unmapped',                    d(51), '[]', now(), NULL, NULL);
INSERT INTO public.gotickets_event VALUES (8001, 'Billy Joel', (d(40) + time '01:00') AT TIME ZONE 'UTC', 1, 'venue_day_name', now()),
                                          (8002, 'Unmapped GT', (d(41) + time '01:00') AT TIME ZONE 'UTC', NULL, NULL, now());
INSERT INTO public.sg_events_canonical VALUES (5001, 'Billy Joel', d(40), 1, 'matcher_v3', now());
INSERT INTO public.mlb_ticket_game VALUES (777001, 'New York Mets', 'Atlanta Braves', 'Citi Field', d(120), now(), NULL, NULL);
INSERT INTO public.mlb_ticket_team VALUES (121, 'New York Mets', 9121);
INSERT INTO public.performer_external_ids (performer_id, source, external_id, external_name) VALUES
  (13, 'tickpick', '777', 'Boston Celtics (old id)'),     -- the Celtics already hold a TickPick id: 503 is declined, not overwritten
  (11, 'seatgeek', '2001', 'Billy Joel');
INSERT INTO public.aq_performer_map VALUES ('PBJ0001', 'Billy Joel', 11, '{"William Joel","The Piano Man"}');
INSERT INTO public.seatgeek_performer_xref VALUES (12, 'NY Knicks', 'auto_listing');
INSERT INTO public.performer_espn_team_xref VALUES (12, '18', 'nba', 'slug');
INSERT INTO public.axs_event_performer_xref VALUES ('4001', 'ax-11', 'Billy Joel', 11, 'exact');
SELECT public.mapper_views_rebuild(true) ->> 'rebuilt' AS views_built;

\echo == EVENT front door: which EVO event is this listing (every source, its own id)
SELECT q.src, q.id, l.tevo_event_id, l.method, l.origin
  FROM (VALUES ('tickpick','9001'), ('tp','9002'), ('vivid','7001'), ('gotickets','8001'), ('sg','5001'), ('axs','4001'),
               ('stubhub','6001'), ('seatdata','6501'), ('evo','1'), ('mlb','777001'), ('gotickets','8002'), ('tickpick','not-a-number')) q(src, id)
  LEFT JOIN LATERAL public.event_map_lookup(q.src, q.id) l ON true ORDER BY q.src, q.id;

\echo == EVENT front door, the other way: an EVO event on every source
SELECT * FROM public.event_map_ids(1) ORDER BY source, source_event_id;
SELECT * FROM public.event_map_ids(2) ORDER BY source, source_event_id;

\echo == VENUE front door
SELECT q.label, r.tevo_venue_id, r.method, r.origin
  FROM (VALUES (1, 'TickPick venue id, two stores agree',        'tickpick', '1',  NULL, NULL, NULL),
               (2, 'TickPick venue id, two stores DISAGREE',     'tickpick', '77', NULL, NULL, NULL),
               (3, 'Vivid venue id',                             'vivid',    '23', NULL, NULL, NULL),
               (4, 'AXS venue id',                               'axs',      '555',NULL, NULL, NULL),
               (5, 'a name the shared resolver knows',           NULL,       NULL, 'Madison Square Garden', NULL, 'NY'),
               (6, 'a name only a catalogue knows (before sync)',NULL,       NULL, 'Capital One Arena', NULL, 'DC'),
               (7, 'a name two venues share in the state',       NULL,       NULL, 'Palace Theatre', NULL, 'NY'),
               (8, '…told apart by the city',                    NULL,       NULL, 'Palace Theatre', 'Albany', 'NY'),
               (9, 'unpaired venue id, unknown name',            'tickpick', '9',  'Nowhere Hall', 'Reno', 'NV')) q(n, label, src, id, nm, city, st)
  LEFT JOIN LATERAL public.venue_map_resolve(q.src, q.id, q.nm, q.city, q.st) r ON true ORDER BY q.n;
SELECT source, source_venue_id, venue_name, tevo_venues, pairings FROM public.v_venue_map_conflicts;

\echo == VENUE sync, dry run: what would be copied into the table the shared resolver reads
SELECT out_(public.venue_map_sync(false));
SELECT count(*) AS rows_before FROM public.cross_source_venue_map;

\echo == VENUE sync, applied
SELECT out_(public.venue_map_sync(true));
SELECT tevo_venue_id, tevo_venue_name, canonical_name, city, state, tickpick_venue_id, tickpick_aliases, vivid_aliases, gotickets_aliases,
       id_provenance ? 'venue_map_sync' AS from_sync
  FROM public.cross_source_venue_map ORDER BY tevo_venue_id;
SELECT action, source, source_id, tevo_id FROM public.mapper_sync_audit ORDER BY action, tevo_id, source, source_id;

\echo == …and the shared resolver now reads them (the function itself was not touched)
SELECT q.nm, q.st, public.cross_source_venue_resolve(q.nm, NULL, q.st) AS tevo_venue_id
  FROM (VALUES ('Capital One Arena', 'DC'), ('Rodgers Theatre', 'NY'), ('Echo Lounge & Music Hall', 'TX'), ('The Anthem', 'DC'), ('Anthem DC', 'DC'),
               ('Sphere', 'NV'), ('Arena DC', 'DC'), ('The Anthem Parking', 'DC'), ('Madison Square Garden Parking', 'NY'), ('Palace Theatre', 'NY')) q(nm, st);

\echo == VENUE sync again: nothing left to do; and the limit
SELECT out_(public.venue_map_sync(true));
DELETE FROM public.cross_source_venue_map WHERE tevo_venue_id IN (300, 800, 900);
SELECT j->>'new_rows' AS new_rows, j->>'waiting_for_next_run' AS waiting FROM (SELECT public.venue_map_sync(false, 1) j) z;

\echo == PERFORMER front door, before the derive
SELECT q.label, r.tevo_performer_id, r.method, r.origin
  FROM (VALUES (1, 'SeatGeek id',                     'seatgeek', '2001', NULL, false),
               (2, 'MLB team id',                     'mlb',      '121',  NULL, false),
               (3, 'AXS artist id',                   'axs',      'ax-11',NULL, false),
               (4, 'TickPick id (not learned yet)',   'tickpick', '501',  NULL, false),
               (5, 'exact name, the TEvo list',       NULL, NULL, 'billy joel', false),
               (6, 'exact name, a store alias',       NULL, NULL, 'The Piano Man', false),
               (7, 'exact name, the SeatGeek store',  NULL, NULL, 'NY Knicks', false),
               (8, 'a near name, exact only',         NULL, NULL, 'Billy Joel Tribute', false),
               (9, 'a near name, guess allowed',      NULL, NULL, 'Billy Joel Tribute', true)) q(n, label, src, id, nm, fz)
  LEFT JOIN LATERAL public.performer_map_resolve(q.src, q.id, q.nm, q.fz) r ON true ORDER BY q.n;

\echo == PERFORMER derive, dry run then applied
SELECT out_(public.performer_map_derive(false));
SELECT count(*) AS rows_before FROM public.performer_external_ids;
SELECT out_(public.performer_map_derive(true));
SELECT source, external_id, external_name, performer_id, meta->>'evidence' AS evidence, meta->>'share' AS share, meta->>'name_overlap' AS overlap
  FROM public.performer_external_ids WHERE meta->>'derived_by' = 'performer_map_derive' ORDER BY source, external_id::int;
\echo    not learned: 503 Celtics (the performer already holds another TickPick id), 504 "LA Lakers" (an away team whose name is not the EVO name),
\echo    505 "Hamilton - The Musical", 510 and 514 "Hamil" (name does not fit), 511 (evidence split), 512 "Billy Joel Parking" (never read),
\echo    516 "Swan" (one event, and "Swan" is not "Swan Lake"), Vivid 801 and 899 (both want Billy Joel on equal evidence)
SELECT q.label, r.tevo_performer_id, r.method, r.origin
  FROM (VALUES (1, 'TickPick id, now learned',  'tickpick', '501'), (2, 'TickPick home team', 'tp', '502'), (3, 'TickPick "U2" (no long word)', 'tickpick', '506'),
               (4, 'Vivid id',                  'vivid',    '801'), (5, 'Vivid away team',    'vivid', '803'), (6, 'TickPick declined id', 'tickpick', '504')) q(n, label, src, id)
  LEFT JOIN LATERAL public.performer_map_resolve(q.src, q.id) r ON true ORDER BY q.n;
SELECT out_(public.performer_map_derive(true)) AS "again: nothing new";

\echo == one shape for every source, and the coverage readout
SELECT source, count(*) AS listings, count(tevo_event_id) AS mapped FROM public.v_event_map GROUP BY 1 ORDER BY 1;
SELECT * FROM public.v_mapper_coverage ORDER BY mapper, source;

\echo == Ticketmaster and ESPN join when their tables exist (prod today; main once PR #1156 lands)
SELECT public.mapper_views_rebuild() AS "same tables: not rebuilt";
CREATE TABLE public.tm_discovery_event (tm_event_id text PRIMARY KEY, name text, local_date date, last_seen_at timestamptz, tevo_event_id bigint, tevo_match_method text);
INSERT INTO public.tm_discovery_event VALUES ('vvG1abc', 'Billy Joel', d(40), now(), 1, 'venue_date_name'), ('vvG1zzz', 'Unmapped TM', d(41), now(), NULL, NULL);
CREATE TABLE public.tm_venue_xref (tm_venue_id text PRIMARY KEY, name text, city text, state text, tevo_venue_id bigint, method text);
INSERT INTO public.tm_venue_xref VALUES ('KovZ1', 'Madison Square Garden', 'New York', 'NY', 100, 'norm_city'), ('KovZ2', 'Capital One Arena', 'Washington', 'DC', 800, 'norm_city');
CREATE TABLE public.tm_attraction_xref (tm_attraction_id text PRIMARY KEY, name text, tevo_performer_id bigint, method text);
INSERT INTO public.tm_attraction_xref VALUES ('K8vZ9', 'Billy Joel', 11, 'name'), ('K8vZ8', 'Somebody New', NULL, NULL);
CREATE TABLE public.espn_ticket_game (espn_event_id text PRIMARY KEY, name text, game_at_utc timestamptz, last_seen_at timestamptz, tevo_event_id bigint, tevo_match_method text);
INSERT INTO public.espn_ticket_game VALUES ('401700001', 'Boston Celtics at New York Knicks', (d(44) + time '00:30') AT TIME ZONE 'UTC', now(), 2, 'espn_time_name');
CREATE FUNCTION public.event_key_lookup(p_source text, p_source_event_id bigint) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT 880000 + p_source_event_id WHERE p_source = 'vivid' $$;
CREATE FUNCTION public.event_key_lookup_tm(p_tm_event_id text) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT 990001::bigint WHERE p_tm_event_id = 'vvG1abc' $$;
SELECT public.mapper_sync_tick(false) -> 'views' AS "the daily pass sees the new tables";
SELECT j #>> '{venue_map_sync,applied}' AS venue_copy_applied, j #>> '{performer_map_derive,applied}' AS performer_derive_applied
  FROM (SELECT public.mapper_sync_tick(true) j) z;   -- what the cron calls: performers on, the venue copy a report
SELECT q.src, q.id, l.tevo_event_id, l.method, l.origin, l.event_key
  FROM (VALUES ('ticketmaster','vvG1abc'), ('tm','vvG1zzz'), ('espn','401700001'), ('vivid','7001'), ('vivid','7004')) q(src, id)
  LEFT JOIN LATERAL public.event_map_lookup(q.src, q.id) l ON true ORDER BY q.src, q.id;
SELECT * FROM public.event_map_ids(1) WHERE source IN ('ticketmaster', 'espn') ORDER BY 1, 2;
SELECT * FROM public.event_map_ids(2) WHERE source IN ('ticketmaster', 'espn') ORDER BY 1, 2;
SELECT r.* FROM public.venue_map_resolve('ticketmaster', 'KovZ2') r;
SELECT r.* FROM public.performer_map_resolve('tm', 'K8vZ9') r;
SELECT mapper, source, total, mapped FROM public.v_mapper_coverage WHERE source IN ('ticketmaster', 'espn') ORDER BY 1, 2;
SELECT j->>'new_rows' AS "venue 800 again, now with Ticketmaster as a source", j->>'pairings_read' AS pairings FROM (SELECT public.venue_map_sync(false) j) z;

\echo == guards
SELECT err_($$SELECT * FROM public.event_map_lookup('craigslist', '1')$$)      AS "unknown source (event)";
SELECT err_($$SELECT * FROM public.venue_map_resolve('craigslist', '1')$$)     AS "unknown source (venue)";
SELECT err_($$SELECT * FROM public.performer_map_resolve('craigslist', '1')$$) AS "unknown source (performer)";
SELECT r AS role,
       has_function_privilege(r, 'public.venue_map_sync(boolean,integer)', 'EXECUTE') AS sync,
       has_function_privilege(r, 'public.event_map_lookup(text,text)', 'EXECUTE') AS lookup,
       has_table_privilege(r, 'public.v_event_map', 'SELECT') AS view_event,
       has_table_privilege(r, 'public.v_performer_map', 'SELECT') AS view_performer,
       has_table_privilege(r, 'public.mapper_sync_audit', 'SELECT') AS audit
  FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r;
SELECT jobname, schedule, command ~ 'cron_should_fire' AS gated FROM cron.job;
SELECT jobname, peak_min_interval_min, enabled FROM public.cron_policy;
SELECT kind, applied, count(*) AS runs FROM public.mapper_sync_run GROUP BY 1, 2 ORDER BY 1, 2;
