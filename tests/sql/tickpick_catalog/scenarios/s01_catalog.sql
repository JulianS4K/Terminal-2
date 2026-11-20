-- TickPick catalogue: pull paging, upserts, the mapper's methods, hub / order / venue fills, drops, idempotence.
-- Dates are relative to today so the output is stable. The stub venue zone reads local wall time as UTC.
\set QUIET 1
\pset footer off
\pset format aligned
SET client_min_messages = warning;

CREATE FUNCTION d(n int) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') $$;
CREATE FUNCTION loc(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT d(n) || 'T' || hm || ':00' $$;
-- a catalogue event as TickPick serves it
CREATE FUNCTION tp_ev(id bigint, nm text, vid bigint, vname text, vcity text, vstate text, n int, hm text, status text DEFAULT 'scheduled',
                      perfs jsonb DEFAULT '[]', extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('event_id', id::text, 'name', nm, 'status', status,
           'event_date', loc(n, hm), 'event_date_utc', loc(n, hm) || 'Z', 'timezone', 'America/New_York',
           'date_confirmed', true, 'time_confirmed', true,
           'category', jsonb_build_object('parent', 'CONCERTS', 'child', 'ROCK', 'grandchild', '-'),
           'venue', jsonb_build_object('venue_id', vid, 'name', vname, 'city', vcity, 'state', vstate, 'country', 'US'),
           'performers', perfs) || extra $$;
CREATE FUNCTION page(evs jsonb, more boolean, cur text) RETURNS text LANGUAGE sql AS $$
  SELECT jsonb_build_object('events', evs, 'has_more', more, 'next_cursor', cur)::text $$;
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT jsonb_pretty((j - 'run_id') || CASE WHEN j ? 'map' THEN jsonb_build_object('map', (j->'map') - 'run_id') ELSE '{}'::jsonb END) $$;

-- ───────── EVO mirror, hub, venue maps, our order book ─────────
INSERT INTO public.events (id, name, occurs_at_local, state, venue_id, venue_name, primary_performer_id, primary_performer_name) VALUES
  (1,  'Billy Joel',                        loc(3, '20:00'), 'shown', 100, 'Madison Square Garden', 11, 'Billy Joel'),
  (2,  'New York Knicks vs Boston Celtics', loc(5, '19:30'), 'shown', 100, 'Madison Square Garden', 12, 'New York Knicks'),
  (3,  'New York Knicks vs Boston Celtics', loc(5, '12:00'), 'shown', 100, 'Madison Square Garden', 12, 'New York Knicks'),
  (4,  'Golden State Warriors vs Boston Celtics', loc(5, '17:30'), 'shown', 200, 'Chase Center', 13, 'Golden State Warriors'),
  (5,  'Billy Joel - PARKING',              loc(3, '20:00'), 'shown', 100, 'Madison Square Garden', 11, 'Billy Joel'),
  (6,  'Dave Matthews Band',                loc(10, '19:00'), 'shown', 300, 'Fenway Park', 14, 'Dave Matthews Band'),
  (7,  'Dave Matthews Band',                loc(10, '19:00'), 'shown', 300, 'Fenway Park', 14, 'Dave Matthews Band'),
  (8,  'Hamilton',                          loc(2, '19:30'), 'shown', 400, 'Kennedy Center', 15, 'Hamilton'),
  (9,  'Billy Joel',                        loc(3, '20:00'), 'ignored', 100, 'Madison Square Garden', 11, 'Billy Joel'),
  (10, 'Lady Gaga',                         loc(7, '20:00'), 'shown', 100, 'Madison Square Garden', 16, 'Lady Gaga'),
  (11, 'Phish',                             loc(8, '19:00'), 'shown', 100, 'Madison Square Garden', 17, 'Phish'),
  (12, 'Taylor Swift',                      loc(20, '19:00'), 'shown', 200, 'Chase Center', 18, 'Taylor Swift');
INSERT INTO public.aq_event_map (aq_short_event_id, event_name, venue_name, aq_source, imported_at, tevo_event_id, tp_event_id) VALUES
  ('AQ-1',  'Billy Joel', 'Madison Square Garden', 'aq_curated', now(), 1, NULL),
  ('AQ-2',  'Knicks vs Celtics', 'Madison Square Garden', 'aq_curated', now(), 2, NULL),
  ('AQ-4',  'Warriors vs Celtics', 'Chase Center', 'aq_curated', now(), 4, NULL),
  ('AQ-10', 'Lady Gaga', 'Madison Square Garden', 'aq_curated', now(), 10, 9010),
  ('AQ-11', 'Phish', 'Madison Square Garden', 'aq_curated', now(), 11, NULL),
  ('AQ-12', 'Taylor Swift', 'Chase Center', 'aq_curated', now(), 12, NULL);
INSERT INTO public.aq_venue_map (venue_short_id, venue_name, city, state, tevo_venue_id, tickpick_venue_id) VALUES
  ('V-100', 'Madison Square Garden', 'New York', 'NY', 100, 1100),
  ('V-200', 'Chase Center', 'San Francisco', 'CA', 200, NULL),
  ('V-300', 'Fenway Park', 'Boston', 'MA', 300, NULL),
  ('V-400', 'Kennedy Center', 'Washington', 'DC', 400, NULL);
INSERT INTO public.cross_source_venue_map (tevo_venue_id, tevo_venue_name, tickpick_venue_id) VALUES
  (200, 'Chase Center', 1200), (300, 'Fenway Park', 1300), (301, 'Fenway Park (lot)', 1300);   -- Fenway's id is contested
INSERT INTO public.tickpick_orders (tp_order_id, event_name, event_date, status, quantity, tevo_event_id, raw, matched_via) VALUES
  ('O1', 'Phish', (loc(8, '19:00'))::timestamptz, 'CONFIRMED', 2, 11, jsonb_build_object('event', jsonb_build_object('event_id', '9011')), 'venue_day_name'),
  ('O2', 'Billy Joel', (loc(3, '20:00'))::timestamptz, 'CONFIRMED', 2, NULL, jsonb_build_object('event', jsonb_build_object('event_id', '9001')), NULL),
  ('O3', 'Billy Joel', (loc(3, '20:00'))::timestamptz, 'CONFIRMED', 4, 5, jsonb_build_object('event', jsonb_build_object('event_id', '9001')), 'venue_day_name');

-- ───────── the catalogue pages the stub serves ─────────
INSERT INTO public.stub_http_page (match, body) VALUES
  ('dateTo=' || d(60), page(jsonb_build_array(
      tp_ev(9001, 'Billy Joel', 1100, 'Madison Square Garden', 'New York', 'NY', 3, '20:00', 'scheduled', '[{"performer_id":"11","name":"Billy Joel","role":"Headliner"}]'),
      tp_ev(9002, 'New York Knicks vs. Boston Celtics', 1100, 'Madison Square Garden', 'New York', 'NY', 5, '19:30', 'scheduled',
            '[{"performer_id":"12","name":"New York Knicks","role":"Home Team"},{"performer_id":"19","name":"Boston Celtics","role":"Away Team"}]'),
      tp_ev(9003, 'Warriors vs. Celtics', 1200, 'Chase Center', 'San Francisco', 'CA', 5, '17:30', 'scheduled',
            '[{"performer_id":"13","name":"Golden State Warriors","role":"Home Team"},{"performer_id":"19","name":"Boston Celtics","role":"Away Team"}]'),
      tp_ev(9004, 'Dave Matthews Band', 1300, 'Fenway Park', 'Boston', 'MA', 10, '19:00'),
      tp_ev(9005, 'Hamilton', 1400, 'Kennedy Center', 'Washington', 'DC', 2, '19:30'),
      tp_ev(9006, 'Billy Joel', 1100, 'Madison Square Garden', 'New York', 'NY', 3, '20:00', 'canceled')
    ), true, 'C2')),
  ('dateTo=' || d(60) || '&cursor=C2', page(jsonb_build_array(
      tp_ev(9007, 'Billy Joel (merged)', 1100, 'Madison Square Garden', 'New York', 'NY', 3, '20:00', 'scheduled', '[]', '{"merged_into":"9001"}'),
      tp_ev(9008, 'Placeholder Show', 1100, 'Madison Square Garden', 'New York', 'NY', 3, '03:30', 'scheduled', '[]', '{"date_confirmed":false,"time_confirmed":false}'),
      tp_ev(9010, 'Lady Gaga', 1100, 'Madison Square Garden', 'New York', 'NY', 7, '20:00'),
      tp_ev(9011, 'Phish', 1100, 'Madison Square Garden', 'New York', 'NY', 8, '19:00'),
      tp_ev(9012, 'Taylor Swift | The Eras Tour', 1200, 'Chase Center', 'San Francisco', 'CA', 20, '19:00', 'scheduled', '[{"performer_id":"18","name":"Taylor Swift"}]'),
      tp_ev(9013, 'Billy Joel Parking', 1100, 'Madison Square Garden', 'New York', 'NY', 3, '20:00'),
      tp_ev(9014, 'Knicks vs Celtics', 1100, 'Madison Square Garden', 'New York', 'NY', 5, '12:00'),
      tp_ev(9015, 'Knicks vs Celtics (matinee)', 1100, 'Madison Square Garden', 'New York', 'NY', 5, '12:00')
    ), false, NULL)),
  ('dateTo=' || d(730), page(jsonb_build_array(
      tp_ev(9020, 'Far Future Fest', 1200, 'Chase Center', 'San Francisco', 'CA', 500, '19:00')
    ), false, NULL));

\echo '== the window pull: two pages, resumed by cursor'
SELECT out_(public.tickpick_catalog_pull('window', current_date, current_date + 60, 1));
SELECT kind, pages_total, events_total, next_cursor, finished_at IS NULL AS open FROM public.tickpick_catalog_sync WHERE kind = 'window';
SELECT out_(public.tickpick_catalog_pull('window', current_date, current_date + 60, 10));
SELECT kind, pages_total, events_total, next_cursor, finished_at IS NULL AS open FROM public.tickpick_catalog_sync WHERE kind = 'window';
\echo '== the catalogue as stored (relative day, confirmed flags, merged, category)'
SELECT tp_event_id, name, status, merged_into, event_date - current_date AS day, time_confirmed AS timed, date_confirmed AS dated,
       tp_venue_id, cat_parent, jsonb_array_length(performers) AS perfs
  FROM public.tickpick_catalog_event ORDER BY tp_event_id;
SELECT tp_venue_id, name, state, timezone FROM public.tickpick_catalog_venue ORDER BY 1;
\echo '== every request was a GET with the vault token'
SELECT method, auth, count(*) FROM public.stub_http_log GROUP BY 1, 2;

\echo '== dry run'
SELECT out_(public.tickpick_catalog_map(false));
SELECT count(*) AS matched_after_dry_run FROM public.tickpick_catalog_event WHERE tevo_event_id IS NOT NULL;
SELECT count(*) AS audit_after_dry_run FROM public.tickpick_catalog_audit;

\echo '== apply'
SELECT out_(public.tickpick_catalog_map(true));
SELECT tp_event_id, name, tevo_event_id, tevo_match_method FROM public.tickpick_catalog_event ORDER BY tp_event_id;
\echo '-- venues: aq_venue_map for MSG, cross_source for Chase (2 matched events corroborate), Fenway contested, Kennedy unknown'
SELECT tp_venue_id, tevo_venue_id, method, events FROM public.tickpick_catalog_venue ORDER BY 1;
\echo '-- the hub: TickPick ids filled on the rows of matched events'
SELECT aq_short_event_id, tevo_event_id, tp_event_id FROM public.aq_event_map ORDER BY 1;
\echo '-- orders: O2 filled by id with the concert, O3 (mapped to the parking row) disagrees: audited, kept; O1 untouched'
SELECT tp_order_id, tevo_event_id, matched_via, match_confidence FROM public.tickpick_orders ORDER BY 1;
\echo '-- aq_venue_map: Chase gets its TickPick id (corroborated); Fenway and Kennedy stay empty'
SELECT venue_short_id, tevo_venue_id, tickpick_venue_id FROM public.aq_venue_map ORDER BY 1;
SELECT action, target, count(*) FROM public.tickpick_catalog_audit GROUP BY 1, 2 ORDER BY 1, 2;
SELECT action, target_key, old_tevo, new_tevo, note FROM public.tickpick_catalog_audit WHERE action = 'order_disagree';

\echo '== second run: nothing changes'
SELECT out_(public.tickpick_catalog_map(true));
SELECT action, count(*) FROM public.tickpick_catalog_audit GROUP BY 1 ORDER BY 1;

\echo '== Taylor Swift moves a day in the catalogue: the match is dropped; a Kennedy Center venue row lets Hamilton map'
UPDATE public.stub_http_page SET body = replace(body, loc(20, '19:00'), loc(21, '19:00')) WHERE match = 'dateTo=' || d(60) || '&cursor=C2';
INSERT INTO public.tickpick_catalog_venue (tp_venue_id, tevo_venue_id, method) VALUES (1400, 400, 'manual')
  ON CONFLICT (tp_venue_id) DO UPDATE SET tevo_venue_id = 400, method = 'manual';
SELECT out_(public.tickpick_catalog_tick());
SELECT tp_event_id, name, event_date - current_date AS day, tevo_event_id, tevo_match_method FROM public.tickpick_catalog_event WHERE tp_event_id IN (9005, 9012, 9020) ORDER BY 1;
SELECT action, note FROM public.tickpick_catalog_audit WHERE tp_event_id = 9012 ORDER BY id;
SELECT kind, pages_total, events_total, next_cursor IS NULL AS at_start, finished_at IS NOT NULL AS done FROM public.tickpick_catalog_sync ORDER BY 1;

\echo '== a manual Fenway row: two matches there write the aq_venue_map id; one Dave Matthews show gone, the other is unambiguous'
INSERT INTO public.tickpick_catalog_venue (tp_venue_id, tevo_venue_id, method) VALUES (1300, 300, 'manual') ON CONFLICT (tp_venue_id) DO UPDATE SET tevo_venue_id = 300, method = 'manual';
INSERT INTO public.events (id, name, occurs_at_local, state, venue_id, venue_name, primary_performer_id, primary_performer_name) VALUES
  (13, 'Red Sox vs Yankees', loc(12, '19:10'), 'shown', 300, 'Fenway Park', 20, 'Boston Red Sox');
INSERT INTO public.tickpick_catalog_event (tp_event_id, name, status, event_local, event_utc, timezone, tp_venue_id, venue_name, performers)
VALUES (9021, 'Boston Red Sox vs. New York Yankees', 'scheduled', loc(12, '19:10')::timestamp, (loc(12, '19:10') || 'Z')::timestamptz, 'America/New_York', 1300, 'Fenway Park',
        '[{"performer_id":"20","name":"Boston Red Sox","role":"Home Team"},{"performer_id":"21","name":"New York Yankees","role":"Away Team"}]');
DELETE FROM public.events WHERE id = 7;      -- one Dave Matthews show gone: the other is now unambiguous
SELECT out_(public.tickpick_catalog_map(true));
SELECT tp_event_id, tevo_event_id, tevo_match_method FROM public.tickpick_catalog_event WHERE tp_venue_id = 1300 ORDER BY 1;
SELECT venue_short_id, tevo_venue_id, tickpick_venue_id FROM public.aq_venue_map ORDER BY 1;

\echo '== grants'
SELECT p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon, has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname LIKE 'tickpick_catalog_%' ORDER BY 1;
SELECT jobname, schedule FROM cron.job ORDER BY 1;
