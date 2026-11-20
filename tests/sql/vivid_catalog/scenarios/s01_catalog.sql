-- Vivid catalogue: the page cursor (resume, empty page ends the pass, 6 h rest), upserts, the mapper's methods,
-- hub / order fills, drops, idempotence. Dates are relative to today; Vivid venues are given timezone UTC so the
-- stub's tevo_event_utc (local read as UTC) lines up.
\set QUIET 1
\pset footer off
\pset format aligned
SET client_min_messages = warning;

CREATE FUNCTION d(n int) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') $$;
CREATE FUNCTION loc(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT d(n) || 'T' || hm || ':00' $$;
CREATE FUNCTION vv_ev(id bigint, nm text, vid bigint, vname text, vcity text, vstate text, n int, hm text, perfs jsonb DEFAULT '[]', cat text DEFAULT 'Pop', etype text DEFAULT 'CONCERT')
 RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('eventId', id, 'eventName', nm, 'eventDate', loc(n, hm), 'eventDateString', loc(n, hm),
           'venue', jsonb_build_object('venueId', vid, 'name', vname, 'city', vcity, 'state', vstate, 'countryCode', 'US', 'regionId', 1, 'timezone', 'UTC'),
           'performers', CASE WHEN perfs = '[]'::jsonb
                              THEN jsonb_build_array(jsonb_build_object('performerId', id * 10, 'name', nm, 'master', true, 'eventType', etype,
                                                                        'category', jsonb_build_object('categoryId', 1, 'name', cat, 'eventType', etype),
                                                                        'url', 'https://x', 'cmsPath', '/x', 'slug', 'x'))
                              ELSE perfs END,
           'listingCount', 3, 'ticketCount', 12, 'integrationType', 'NONE', 'url', '', 'webPath', '', 'categoryId', 0) $$;
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$ SELECT jsonb_pretty(j - 'run_id') $$;

INSERT INTO public.events (id, name, occurs_at_local, state, venue_id, venue_name, primary_performer_id, primary_performer_name) VALUES
  (1,  'Billy Joel',                              loc(3, '20:00'),  'shown', 100, 'Madison Square Garden', 11, 'Billy Joel'),
  (2,  'New York Knicks vs Boston Celtics',       loc(5, '19:30'),  'shown', 100, 'Madison Square Garden', 12, 'New York Knicks'),
  (3,  'New York Knicks vs Boston Celtics',       loc(5, '12:00'),  'shown', 100, 'Madison Square Garden', 12, 'New York Knicks'),
  (4,  'Golden State Warriors vs Boston Celtics', loc(5, '17:30'),  'shown', 200, 'Chase Center', 13, 'Golden State Warriors'),
  (5,  'Billy Joel - PARKING',                    loc(3, '20:00'),  'shown', 100, 'Madison Square Garden', 11, 'Billy Joel'),
  (6,  'Hamilton',                                loc(2, '19:30'),  'shown', 400, 'Kennedy Center', 15, 'Hamilton'),
  (7,  'Hamilton',                                loc(2, '14:00'),  'shown', 400, 'Kennedy Center', 15, 'Hamilton'),
  (10, 'Lady Gaga',                               loc(7, '20:00'),  'shown', 100, 'Madison Square Garden', 16, 'Lady Gaga'),
  (11, 'Phish',                                   loc(8, '19:00'),  'shown', 200, 'Chase Center', 17, 'Phish'),
  (12, 'Taylor Swift',                            loc(20, '19:00'), 'shown', 200, 'Chase Center', 18, 'Taylor Swift');
INSERT INTO public.aq_event_map (aq_short_event_id, event_name, venue_name, aq_source, imported_at, tevo_event_id, vivid_event_id) VALUES
  ('AQ-1',  'Billy Joel', 'MSG', 'aq_curated', now(), 1, NULL),
  ('AQ-2',  'Knicks vs Celtics', 'MSG', 'aq_curated', now(), 2, NULL),
  ('AQ-4',  'Warriors vs Celtics', 'Chase', 'aq_curated', now(), 4, NULL),
  ('AQ-10', 'Lady Gaga', 'MSG', 'aq_curated', now(), 10, 9010),
  ('AQ-11', 'Phish', 'Chase', 'aq_curated', now(), 11, NULL),
  ('AQ-12', 'Taylor Swift', 'Chase', 'aq_curated', now(), 12, NULL);
INSERT INTO public.vivid_orders (vivid_order_id, event_name, event_date, status, quantity, tevo_event_id, raw) VALUES
  ('V1', 'Phish', loc(8, '19:00')::timestamptz, 'CONFIRMED', 2, 11, '{"productionId": "9011", "eventId": "555"}'),
  ('V2', 'Billy Joel', loc(3, '20:00')::timestamptz, 'CONFIRMED', 2, NULL, '{"productionId": "9001", "eventId": "556"}'),
  ('V3', 'Billy Joel', loc(3, '20:00')::timestamptz, 'CONFIRMED', 4, 5, '{"productionId": "9001", "eventId": "556"}');

-- three pages: 1 and 2 full of events, 3 empty (the pass ends there)
INSERT INTO public.stub_http_page (match, body) VALUES
  ('page=1', jsonb_build_array(
      vv_ev(9001, 'Billy Joel', 1100, 'Madison Square Garden', 'New York', 'NY', 3, '20:00'),
      vv_ev(9002, 'New York Knicks at Boston Celtics', 1100, 'Madison Square Garden', 'New York', 'NY', 5, '19:30',
            '[{"performerId": 12, "name": "New York Knicks", "master": true, "eventType": "SPORT", "category": {"categoryId": 2, "name": "NBA", "eventType": "SPORT"}},
              {"performerId": 19, "name": "Boston Celtics", "master": false, "eventType": "SPORT", "category": {"categoryId": 2, "name": "NBA", "eventType": "SPORT"}}]'),
      vv_ev(9003, 'Golden State Warriors vs. Boston Celtics', 1200, 'Chase Center', 'San Francisco', 'CA', 5, '17:30'),
      vv_ev(9005, 'Hamilton', 1400, 'Kennedy Center', 'Washington', 'DC', 2, '00:00'),
      vv_ev(9010, 'Lady Gaga', 1100, 'Madison Square Garden', 'New York', 'NY', 7, '20:00'))::text),
  ('page=2', jsonb_build_array(
      vv_ev(9011, 'Phish', 1200, 'Chase Center', 'San Francisco', 'CA', 8, '19:00'),
      vv_ev(9012, 'Taylor Swift | The Eras Tour', 1200, 'Chase Center', 'San Francisco', 'CA', 20, '19:00'),
      vv_ev(9013, 'Billy Joel Parking', 1100, 'Madison Square Garden', 'New York', 'NY', 3, '20:00'),
      vv_ev(9014, 'Knicks vs Celtics', 1100, 'Madison Square Garden', 'New York', 'NY', 5, '12:00'),
      vv_ev(9015, 'Knicks vs Celtics (matinee)', 1100, 'Madison Square Garden', 'New York', 'NY', 5, '12:00'))::text),
  ('page=3', '[]');

\echo '== the migration pulled page 1; the tick carries the pass on and the empty page ends it'
SELECT next_page, pages_total, events_total, pass_finished_at IS NULL AS open FROM public.vivid_catalog_sync;
SELECT out_(public.vivid_catalog_tick());
SELECT next_page, pages_total, events_total, pass_finished_at IS NOT NULL AS done FROM public.vivid_catalog_sync;
SELECT (public.vivid_catalog_tick())->>'idle' AS idle;      -- rests until the pass is 6 h old
SELECT method, auth, count(*) FROM public.stub_http_log GROUP BY 1, 2;
SELECT vivid_event_id, name, event_date - current_date AS day, time_known, category, event_type, vivid_venue_id, jsonb_array_length(performers) AS perfs
  FROM public.vivid_catalog_event ORDER BY 1;
SELECT vivid_venue_id, name, state, timezone FROM public.vivid_catalog_venue ORDER BY 1;

\echo '== dry run, then apply'
SELECT out_(public.vivid_catalog_map(false));
SELECT count(*) AS matched_after_dry_run FROM public.vivid_catalog_event WHERE tevo_event_id IS NOT NULL;
SELECT out_(public.vivid_catalog_map(true));
SELECT vivid_event_id, name, tevo_event_id, tevo_match_method FROM public.vivid_catalog_event ORDER BY 1;
\echo '-- Hamilton (midnight placeholder, two shows that day) stays ambiguous; venues learned from matches'
SELECT vivid_venue_id, tevo_venue_id, method, events FROM public.vivid_catalog_venue ORDER BY 1;
SELECT aq_short_event_id, tevo_event_id, vivid_event_id FROM public.aq_event_map ORDER BY 1;
\echo '-- V2 filled by id with the concert; V3 (mapped to the parking row) disagrees: audited, kept'
SELECT vivid_order_id, tevo_event_id FROM public.vivid_orders ORDER BY 1;
SELECT action, target, count(*) FROM public.vivid_catalog_audit GROUP BY 1, 2 ORDER BY 1, 2;

\echo '== second run: nothing changes'
SELECT out_(public.vivid_catalog_map(true));

\echo '== Taylor Swift moves a day: dropped; a manual Kennedy Center row does not rescue Hamilton (two shows, no time)'
UPDATE public.stub_http_page SET body = replace(body, loc(20, '19:00'), loc(21, '19:00')) WHERE match = 'page=2';
UPDATE public.vivid_catalog_sync SET pass_finished_at = now() - interval '7 hours';
SELECT (public.vivid_catalog_tick())->>'pass_done' AS pass_done;
INSERT INTO public.vivid_catalog_venue (vivid_venue_id, tevo_venue_id, method) VALUES (1400, 400, 'manual')
  ON CONFLICT (vivid_venue_id) DO UPDATE SET tevo_venue_id = 400, method = 'manual';
SELECT out_(public.vivid_catalog_map(true));
SELECT vivid_event_id, event_date - current_date AS day, tevo_event_id, tevo_match_method FROM public.vivid_catalog_event WHERE vivid_event_id IN (9005, 9012) ORDER BY 1;
SELECT action, note FROM public.vivid_catalog_audit WHERE vivid_event_id = 9012 ORDER BY id;

\echo '== grants and crons'
SELECT p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon, has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname LIKE 'vivid_catalog_%' ORDER BY 1;
SELECT jobname, schedule FROM cron.job ORDER BY 1;
