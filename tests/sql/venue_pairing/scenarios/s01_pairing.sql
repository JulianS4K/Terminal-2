\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- The venue pairer (mig 20261117140000): each rule on a case it should pair and one it should not, fill-only writes,
-- the audit, a second run with nothing left, the mappers' kept-pairing predicate, the cron.
CREATE FUNCTION d(n int) RETURNS date LANGUAGE sql AS $$ SELECT current_date + n $$;
CREATE FUNCTION at_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') || 'T' || hm || ':00' $$;
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$ SELECT (j - 'run_id' - 'ms')::text $$;

-- the TEvo mirror: venues on upcoming events
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location) VALUES
  (1001, 'Hamilton',               at_(5, '19:30'),  'shown', 100, 'Majestic Theatre - Dallas',                    'Dallas, TX'),
  (1002, 'Blue Man Group',         at_(10, '19:00'), 'shown', 110, 'Grand Theater',                                'Wausau, WI'),
  (1003, 'Weird Al Yankovic',      at_(12, '20:00'), 'shown', 110, 'Grand Theater',                                'Wausau, WI'),
  (1004, 'Some Other Show',        at_(11, '20:00'), 'shown', 111, 'Grand Theater',                                'Wausau, WI'),   -- a second TEvo venue of the same name in the city
  (1005, 'Ottawa Senators vs Montreal Canadiens', at_(8, '19:00'), 'shown', 120, 'Canadian Tire Centre',          'Kanata, ON'),
  (1006, 'Moody Blues',            at_(9, '20:00'),  'shown', 130, 'Moody Center',                                 'Austin, TX'),
  (1007, 'Hamilton',               at_(6, '19:30'),  'shown', 140, 'Palace Theatre - Los Angeles',                 'Los Angeles, CA'),
  (1008, 'Tab Benoit',             at_(15, '20:00'), 'shown', 170, 'Boca Black Box Center for the Arts',           'Boca Raton, FL'),
  (1009, 'Street Fair',            at_(16, '12:00'), 'shown', 180, 'Gaslamp Quarter',                              'San Diego, CA'),
  (1010, 'Micro Wrestling',        at_(3, '19:00'),  'shown', 190, 'Micro Wrestling Federation at the Microtorium', 'Pigeon Forge, TN'),
  (1011, 'Micro Wrestling',        at_(4, '19:00'),  'shown', 190, 'Micro Wrestling Federation at the Microtorium', 'Pigeon Forge, TN'),
  (1012, 'Micro Wrestling',        at_(5, '19:00'),  'shown', 190, 'Micro Wrestling Federation at the Microtorium', 'Pigeon Forge, TN'),
  (1013, 'New York Knicks vs Boston Celtics', at_(20, '19:30'), 'shown', 200, 'Madison Square Garden',            'New York, NY'),
  (1014, 'Lucero',                 at_(21, '20:00'), 'shown', 210, 'Cannery Ballroom',                             'Nashville, TN'),
  (1015, 'Jason Isbell',           at_(22, '20:00'), 'shown', 211, 'Mercy Lounge',                                 'Nashville, TN'),
  (1016, 'Menopause The Musical',  at_(7, '19:30'),  'shown', 220, 'Harrah''s Cabaret At Harrah''s Las Vegas',     'Las Vegas, NV'),
  (1017, 'KA',                     at_(7, '19:00'),  'shown', 230, 'KA Theatre at MGM Grand',                      'Las Vegas, NV'),
  (1018, 'Parking: KA',            at_(7, '19:00'),  'shown', 230, 'KA Theatre at MGM Grand',                      'Las Vegas, NV'),
  (1019, 'Gone Show',              at_(-30, '19:00'), 'shown', 240, 'Old Venue',                                   'Dallas, TX');

-- AXS pairs The Sinclair with TEvo venue 150 (which has no upcoming EVO event, so no name rule can see it)
INSERT INTO axs_export_event (axs_event_id, venue_name, venue_city, venue_state, tevo_venue_id) VALUES (5001, 'The Sinclair', 'Cambridge', 'MA', 150), (5002, 'The Sinclair', 'Cambridge', 'MA', 150);

-- TickPick: a manual pairing the Vivid sibling rule can lean on; Microtorium (events only); Penn Plaza (one shared day)
INSERT INTO tickpick_catalog_venue (tp_venue_id, name, city, state, country, tevo_venue_id, method) VALUES
  (21, 'Boondocks Pub', 'Springfield', 'IL', 'US', 160, 'manual'),
  (30, 'Microtorium', 'Pigeon Forge', 'TN', 'US', NULL, NULL),
  (31, 'Penn Plaza', 'New York', 'NY', 'US', NULL, NULL),
  (32, 'Majestic Theatre Dallas', 'Dallas', 'TX', 'US', NULL, NULL);
INSERT INTO tickpick_catalog_event (tp_event_id, name, status, event_date, tp_venue_id) VALUES
  (3001, 'Micro Wrestling', 'active', d(3), 30), (3002, 'Micro Wrestling', 'active', d(4), 30), (3003, 'Micro Wrestling', 'active', d(5), 30),
  (3004, 'New York Knicks vs Boston Celtics', 'active', d(20), 31),
  (3005, 'Hamilton', 'active', d(5), 32);

-- Vivid
INSERT INTO vivid_catalog_venue (vivid_venue_id, name, city, state, country, tevo_venue_id, method) VALUES
  (41, 'Majestic Theatre Dallas',                        'Dallas', 'TX', 'US', NULL, NULL),             -- eq_city
  (42, 'Grand Theater - Wausau',                         'Wausau', 'WI', 'US', NULL, NULL),             -- two equal names in the city: the events decide (cooccur)
  (43, 'Canadian Tire Centre',                           'Ottawa', 'ON', 'CA', NULL, NULL),             -- eq_state (Kanata)
  (44, 'Canadian Tire Centre Parking',                   'Ottawa', 'ON', 'CA', NULL, NULL),             -- eq_state too (parking is dropped from the name)
  (45, 'Moody Center ATX',                               'Austin', 'TX', 'US', 130, 'name_state'),      -- already paired: never touched
  (46, 'Moody Center ATX Parking',                       'Austin', 'TX', 'US', NULL, NULL),             -- parking of 45 (no name rule reaches "Moody Center")
  (47, 'Palace Theatre - San Francisco',                 'San Francisco', 'CA', 'US', NULL, NULL),      -- NOT Los Angeles
  (48, 'The Sinclair',                                   'Cambridge', 'MA', 'US', NULL, NULL),          -- sibling via AXS
  (49, 'Boondocks Pub',                                  'Springfield', 'IL', 'US', NULL, NULL),        -- sibling via TickPick venue 21
  (50, 'Boca Black Box',                                 'Boca Raton', 'FL', 'US', NULL, NULL),         -- affix, corroborated by Tab Benoit
  (51, 'Gaslamp Quarter - The Yellow Door Comedy Club',  'San Diego', 'CA', 'US', NULL, NULL),          -- affix, no shared event: stays
  (52, 'Cannery Hall',                                   'Nashville', 'TN', 'US', NULL, NULL),          -- contested cooccur (1/1): stays
  (53, 'Harrahs Cabaret at Harrahs Las Vegas',           'Las Vegas', 'NV', 'US', NULL, NULL),          -- eq_city (apostrophes)
  (54, 'KA Theatre at MGM Grand Hotel and Casino',       'Las Vegas', 'NV', 'US', NULL, NULL),          -- eq_city (hotel / casino dropped)
  (55, 'O2 Academy',                                     'London', NULL, 'GB', NULL, NULL),             -- not US / CA / MX, no state: skipped
  (56, 'Nowhere Hall',                                   'Dallas', 'TX', 'US', NULL, NULL);             -- no upcoming events: not a candidate
INSERT INTO vivid_catalog_event (vivid_event_id, name, event_date, vivid_venue_id) VALUES
  (4001, 'Hamilton', d(5), 41),
  (4002, 'Blue Man Group', d(10), 42), (4003, 'Weird Al Yankovic', d(12), 42),
  (4004, 'Ottawa Senators vs. Montreal Canadiens', d(8), 43), (4005, 'Ottawa Senators vs. Montreal Canadiens Parking', d(8), 44),
  (4006, 'Moody Blues', d(9), 45), (4007, 'Moody Blues Parking', d(9), 46),
  (4008, 'Hamilton', d(6), 47),
  (4009, 'Phish', d(30), 48),
  (4010, 'Open Mic', d(31), 49),
  (4011, 'Tab Benoit', d(15), 50),
  (4012, 'Comedy Night', d(16), 51),
  (4013, 'Lucero', d(21), 52), (4014, 'Jason Isbell', d(22), 52),
  (4015, 'Menopause The Musical', d(7), 53),
  (4016, 'KA', d(7), 54),
  (4017, 'Some Band', d(9), 55);

\echo A the normaliser
SELECT catalog_venue_norm('Harrahs Cabaret at Harrahs Las Vegas', 'Las Vegas', 'NV'), catalog_venue_norm('Harrah''s Cabaret At Harrah''s Las Vegas', 'Las Vegas', 'NV');
SELECT catalog_venue_norm('KA Theatre at MGM Grand Hotel and Casino', 'Las Vegas', 'NV'), catalog_venue_norm('The Kennedy Centre - Opera House', 'Washington', 'DC'), catalog_venue_norm('Comedy Cellar - Las Vegas', 'Las Vegas', 'NV', false);
SELECT catalog_venue_kept('manual'), catalog_venue_kept('llm_judge'), catalog_venue_kept('pair_eq_city'), catalog_venue_kept('name_state'), catalog_venue_kept(NULL);

\echo B Vivid dry run: 13 candidates (55 and 56 are not), 10 paired (42 by its events: two TEvo venues carry the name), nothing written
SELECT out_(catalog_venue_pair('vivid', false));
SELECT count(*) FROM vivid_catalog_venue WHERE method LIKE 'pair%';

\echo C Vivid live: written and audited; 45 untouched; 47, 51, 52 still open
SELECT (catalog_venue_pair('vivid'))->'written';
SELECT vivid_venue_id, name, tevo_venue_id, method FROM vivid_catalog_venue ORDER BY 1;
SELECT target, target_key, note FROM vivid_catalog_audit WHERE action = 'venue_xref' ORDER BY target_key::int;

\echo D a second run has nothing left to pair
SELECT out_(catalog_venue_pair('vivid'));

\echo E TickPick: Microtorium by the events (3 days), Majestic by name; Penn Plaza (one day) stays
SELECT out_(catalog_venue_pair('tickpick'));
SELECT tp_venue_id, name, tevo_venue_id, method FROM tickpick_catalog_venue ORDER BY 1;

\echo F the review view and the cron
SELECT source, venue_id, name, tevo_name, tevo_location, method FROM v_catalog_venue_pairs WHERE method LIKE 'pair_%' ORDER BY source, venue_id;
SELECT jobname, schedule FROM cron.job ORDER BY 1;
SELECT has_function_privilege('anon', 'catalog_venue_pair(text,boolean)', 'EXECUTE'), has_function_privilege('service_role', 'catalog_venue_pair(text,boolean)', 'EXECUTE');
