\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- Ticketmaster Discovery (mig 20261117180000): the plan, a budgeted GET per page, the landed catalogue, the venue and
-- attraction xrefs, the TEvo match, the budget refusing at 100, GET only, the key never stored.
CREATE FUNCTION d(n int) RETURNS date LANGUAGE sql AS $$ SELECT current_date + n $$;
CREATE FUNCTION at_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') || 'T' || hm || ':00' $$;
CREATE FUNCTION utc_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char((at_(n, hm)::timestamp AT TIME ZONE 'America/New_York') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;
CREATE FUNCTION tm_ev(id text, nm text, n int, hm text, venue_id text, venue text, city text, st text, attrs jsonb, seg text, genre text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('id', id, 'name', nm, 'url', 'https://www.ticketmaster.com/event/' || id,
    'dates', jsonb_build_object('start', jsonb_build_object('localDate', to_char(d(n), 'YYYY-MM-DD'), 'localTime', hm || ':00', 'dateTime', utc_(n, hm), 'dateTBD', false, 'timeTBA', false),
                                'status', jsonb_build_object('code', 'onsale')),
    'sales', jsonb_build_object('public', jsonb_build_object('startDateTime', utc_(-30, '10:00')), 'presales', jsonb_build_array(jsonb_build_object('name', 'Fan Presale'))),
    'ticketLimit', jsonb_build_object('info', 'There is an 8 ticket limit'),
    'classifications', jsonb_build_array(jsonb_build_object('segment', jsonb_build_object('name', seg), 'genre', jsonb_build_object('name', genre), 'subGenre', jsonb_build_object('name', genre))),
    '_embedded', jsonb_build_object('venues', jsonb_build_array(jsonb_build_object('id', venue_id, 'name', venue, 'city', jsonb_build_object('name', city), 'state', jsonb_build_object('stateCode', st), 'country', jsonb_build_object('countryCode', 'US'), 'timezone', 'America/New_York')),
                                    'attractions', attrs)) $$;
CREATE FUNCTION page(evs jsonb, total int, num int) RETURNS text LANGUAGE sql AS $$
  SELECT jsonb_build_object('_embedded', jsonb_build_object('events', evs), 'page', jsonb_build_object('size', 200, 'totalElements', 3, 'totalPages', total, 'number', num))::text $$;

-- the TEvo mirror and performers
INSERT INTO venue_timezone VALUES (1000, 'America/New_York', 'Madison Square Garden'), (1001, 'America/New_York', 'Barclays Center');
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_name) VALUES
  (601, 'Boston Celtics at New York Knicks',   at_(3, '19:30'), 'shown', 1000, 'Madison Square Garden', 'New York, NY', 'New York Knicks'),
  (602, 'Miami Heat at New York Knicks',       at_(5, '19:30'), 'shown', 1000, 'Madison Square Garden', 'New York, NY', 'New York Knicks'),
  (603, 'Parking: Miami Heat at New York Knicks', at_(5, '19:30'), 'shown', 1000, 'Madison Square Garden', 'New York, NY', NULL),
  (604, 'Billy Joel',                          at_(6, '20:00'), 'shown', 1000, 'Madison Square Garden', 'New York, NY', 'Billy Joel'),
  (605, 'Billy Joel',                          at_(6, '14:00'), 'shown', 1000, 'Madison Square Garden', 'New York, NY', 'Billy Joel'),
  (606, 'Orlando Magic at Brooklyn Nets',      at_(4, '19:30'), 'shown', 1001, 'Barclays Center',       'Brooklyn, NY', 'Brooklyn Nets');
INSERT INTO aq_performer_map (performer_short_id, performer_name, tevo_performer_id) VALUES ('p1', 'New York Knicks', 51), ('p2', 'Boston Celtics', 52), ('p3', 'Billy Joel', 53), ('p4', 'Billy Joel', 54);

-- the stubbed Discovery pages: Sports this week, two pages; everything else answers an empty page
INSERT INTO stub_http_page (match, body) VALUES
  ('page=0&', page(jsonb_build_array(
      tm_ev('G5diZ_o6tFFbU', 'New York Knicks vs. Boston Celtics', 3, '19:30', 'KovZpZA7AAEA', 'Madison Square Garden', 'New York', 'NY', '[{"id":"K8vZ9171oZ0","name":"New York Knicks"},{"id":"K8vZ9171oC0","name":"Boston Celtics"}]', 'Sports', 'Basketball'),
      tm_ev('G5diZ_o6tFFbV', 'Brooklyn Nets vs. Orlando Magic',    4, '19:30', 'KovZpZAEkn6A', 'Barclays Ctr',          'Brooklyn', 'NY', '[{"id":"K8vZ9171o70","name":"Brooklyn Nets"},{"id":"K8vZ9171ok7","name":"Orlando Magic"}]', 'Sports', 'Basketball')), 2, 0)),
  ('page=1&', page(jsonb_build_array(
      tm_ev('G5diZ_o6tFFbW', 'New York Knicks vs. Miami Heat',     5, '19:30', 'KovZpZA7AAEA', 'Madison Square Garden', 'New York', 'NY', '[{"id":"K8vZ9171oZ0","name":"New York Knicks"},{"id":"K8vZ9171oE7","name":"Miami Heat"}]', 'Sports', 'Basketball'),
      tm_ev('G5diZ_o6tFFbX', 'Knicks Parking: Miami Heat',         5, '19:30', 'KovZpZA7AAEA', 'Madison Square Garden', 'New York', 'NY', '[]', 'Miscellaneous', 'Parking'),
      tm_ev('3B006511E92086', 'Billy Joel',                        6, '20:00', 'KovZpZA7AAEA', 'Madison Square Garden', 'New York', 'NY', '[{"id":"K8vZ917Gku7","name":"Billy Joel"}]', 'Music', 'Rock')), 2, 1)),
  ('classificationName=Music', page('[]'::jsonb, 1, 0)), ('classificationName=Arts', page('[]'::jsonb, 1, 0));

\echo A the plan: three segments x 13 weeks; nothing called yet
SELECT tm_discovery_plan(13);
SELECT count(*), count(*) FILTER (WHERE active), replace(min(label), date_trunc('week', current_date::timestamp)::date::text, '<this week>') AS first_label, (SELECT params->>'size' FROM tm_discovery_query LIMIT 1) FROM tm_discovery_query;
SELECT params ? 'apikey' AS key_in_plan FROM tm_discovery_query LIMIT 1;

\echo B a tick of two calls: the two pages of the Sports week land five events (one a parking product); the query is complete; the budget counts 2
SELECT tm_discovery_tick(2) - 'run_id' - 'seconds';
SELECT tm_event_id, name, local_date - current_date AS day, local_time, status_code, tm_venue_id, segment, is_product, array_to_string(attraction_names, '|') AS attractions, jsonb_array_length(presales) AS presales, tevo_event_id, tevo_match_method FROM tm_discovery_event ORDER BY tm_event_id COLLATE "C";
SELECT replace(label, date_trunc('week', current_date::timestamp)::date::text, '<this week>') AS label, page, total_pages, events_seen, last_ok_at IS NOT NULL AS complete FROM tm_discovery_query WHERE events_seen > 0;
SELECT day = current_date AS today, calls, refused, cap, burst_calls, tm_available, tm_limit, tm_reset_at AT TIME ZONE 'UTC' AS tm_reset FROM tm_discovery_quota;
\echo B1 GET only, size 200, and the key in the request but nowhere stored
SELECT method, count(*), bool_and(uri LIKE 'https://app.ticketmaster.com/discovery/v2/events.json?%') AS discovery_host, bool_and(uri LIKE '%size=200%') AS size_200, bool_and(uri LIKE '%apikey=STUBKEY%') AS key_in_request FROM stub_http_log GROUP BY 1;
SELECT count(*) AS rows_with_the_key FROM (SELECT params::text AS t FROM tm_discovery_query UNION ALL SELECT note FROM tm_discovery_audit UNION ALL SELECT coalesce(last_error, '') FROM tm_discovery_query UNION ALL SELECT raw::text FROM tm_discovery_event) s WHERE s.t LIKE '%STUBKEY%';

\echo C the xrefs and the match: MSG and Barclays Ctr (ctr reads as center) by name; two TEvo performers called Billy Joel: the attraction stays unpaired; Knicks games by venue + date + name with the Heat game told from its parking; Billy Joel: two shows that day, the 20:00 one by the hour
SELECT tm_venue_id, name, tevo_venue_id, method FROM tm_venue_xref ORDER BY tm_venue_id COLLATE "C";
SELECT tm_attraction_id, name, tevo_performer_id, method FROM tm_attraction_xref ORDER BY tm_attraction_id COLLATE "C";
SELECT tm_event_id, tm_name, evo_name, tevo_match_method FROM v_tm_discovery_link ORDER BY tm_event_id COLLATE "C";
SELECT action, count(*) FROM tm_discovery_audit GROUP BY 1 ORDER BY 1;

\echo D the budget: at 100 the call is refused, counted, audited; nothing is fetched
UPDATE tm_discovery_quota SET calls = 100 WHERE day = current_date;
UPDATE tm_discovery_query SET last_ok_at = NULL WHERE label LIKE 'seg:Music:%';
SELECT (tm_discovery_tick(3) - 'run_id' - 'seconds') - 'matched';
SELECT calls, refused FROM tm_discovery_quota WHERE day = current_date;
SELECT count(*) FROM stub_http_log;
\echo D1 a cap raised by data stays at 100
UPDATE tm_discovery_quota SET cap = 100 WHERE day = current_date;
SELECT tm_discovery_call_allowed();
\echo D2 no key: nothing is called
UPDATE tm_discovery_quota SET calls = 0 WHERE day = current_date;
UPDATE vault.decrypted_secrets SET decrypted_secret = '' WHERE name = 'TMR CLIENT ID';
SELECT (tm_discovery_tick(1) - 'run_id' - 'seconds');
SELECT count(*) FROM stub_http_log;

\echo E who may run what; the cron
SELECT has_function_privilege('anon', 'tm_discovery_tick(integer, boolean, integer)', 'EXECUTE'), has_function_privilege('service_role', 'tm_discovery_tick(integer, boolean, integer)', 'EXECUTE'), has_table_privilege('anon', 'tm_discovery_event', 'SELECT');
SELECT jobname, schedule, command LIKE '%tm_discovery_tick(4)%' AS four_calls, command LIKE '%tm_discovery_burst_tick()%' AS burst FROM cron.job ORDER BY 1;

\echo F the one-time burst (mig 20261118001000): the row waits for its window; in it, a probe reads what Ticketmaster says is left; armed above min_available; the state plan exists; the spend is capped per minute and never touches the drip budget
UPDATE vault.decrypted_secrets SET decrypted_secret = 'STUBKEYSTUBKEYSTUBKEYSTUBKEY1234' WHERE name = 'TMR CLIENT ID';
UPDATE tm_discovery_quota SET calls = 0, refused = 0, tm_available = NULL, last_call_at = NULL WHERE day = current_date;
DELETE FROM stub_http_log;
UPDATE stub_http_rate SET start_available = 4100;
SELECT id, min_available, max_per_minute, armed, done, window_start AT TIME ZONE 'UTC' AS starts, window_end AT TIME ZONE 'UTC' AS ends FROM tm_discovery_burst;
UPDATE tm_discovery_burst SET window_start = now() + interval '1 hour', window_end = now() + interval '2 hours';
SELECT tm_discovery_burst_tick() ->> 'state';
UPDATE tm_discovery_burst SET window_start = now() - interval '1 minute', window_end = now() + interval '1 minute';
SELECT (tm_discovery_burst_tick() - 'budget_today' - 'seconds' - 'probe') AS first_run;
SELECT armed, available_at_arm, done, runs, calls, events FROM tm_discovery_burst;
SELECT calls AS drip_calls, burst_calls, refused, tm_available FROM tm_discovery_quota WHERE day = current_date;
SELECT count(*) AS queries, count(*) FILTER (WHERE label LIKE 'st:%') AS state_queries, count(*) FILTER (WHERE label LIKE 'ca:%') AS canada_queries, min(priority) FILTER (WHERE label LIKE 'st:%') AS state_priority FROM tm_discovery_query;
SELECT count(*) AS requests, bool_and(method = 'GET') AS all_get, bool_and(uri LIKE 'https://app.ticketmaster.com/discovery/v2/events.json?%') AS discovery_host, count(*) FILTER (WHERE uri LIKE '%stateCode=%') AS state_requests FROM stub_http_log;
\echo F1 the reserve: with Ticketmaster reporting 12 left, one call goes (its answer says 10 left) and the next is refused
UPDATE tm_discovery_quota SET tm_available = 12 WHERE day = current_date;
UPDATE stub_http_rate SET start_available = 11 + (SELECT count(*) FROM stub_http_log);
SELECT (tm_discovery_burst_tick() - 'budget_today' - 'seconds') AS reserve_run;
SELECT calls AS drip_calls, burst_calls, refused, tm_available FROM tm_discovery_quota WHERE day = current_date;
\echo F2 the window closes: the row is done and the cron is gone; a later run says done
UPDATE tm_discovery_burst SET window_end = now() - interval '1 second';
SELECT tm_discovery_burst_tick() - 'runs' - 'calls' - 'events';
SELECT done, done_reason, armed FROM tm_discovery_burst;
SELECT jobname FROM cron.job ORDER BY 1;
SELECT tm_discovery_burst_tick() ->> 'state';
\echo F3 a window that finds too few left never arms
UPDATE tm_discovery_burst SET done = false, armed = false, window_start = now() - interval '1 minute', window_end = now() + interval '1 minute';
UPDATE tm_discovery_quota SET tm_available = 3000, last_call_at = now() WHERE day = current_date;
SELECT tm_discovery_burst_tick();
SELECT done, done_reason FROM tm_discovery_burst;
SELECT action, count(*) FROM tm_discovery_audit WHERE action IN ('burst', 'refused') GROUP BY 1 ORDER BY 1;
\echo F4 the key is still nowhere stored
SELECT count(*) AS rows_with_the_key FROM (SELECT params::text AS t FROM tm_discovery_query UNION ALL SELECT note FROM tm_discovery_audit UNION ALL SELECT coalesce(last_error, '') FROM tm_discovery_query UNION ALL SELECT raw::text FROM tm_discovery_event UNION ALL SELECT coalesce(last_result::text, '') FROM tm_discovery_burst) s WHERE s.t LIKE '%STUBKEY%';

\echo G seller and channel from the link (migs 20261118003000, 20261122040000): the box office and its partners are primary; a Ticketmaster resale page (/event/Z7r9j...), a resale host or a resale link is secondary; travel and VIP packages are packages; a doubleclick wrapper is unwrapped; no link is unknown
SELECT u, tm_link_seller(u), tm_link_channel(u) FROM unnest(ARRAY[
  'https://www.ticketmaster.com/10-years-tour-minneapolis-12-11-2026/event/060064B5363DCB87',
  'https://www.ticketmaster.ca/curling-saint-john-03-30-2027/event/31006556D8A3D650',
  'https://am.ticketmaster.com/asmgkingston/buy/ism/MjZMRlJJ',
  'https://www.universe.com/events/reserved-luxury-seating-tickets-7NV451?ref=ticketmaster',
  'https://www.ticketweb.ca/event/anna-von-hausswolff-tickets/14564433',
  'https://on.fgtix.com/trk/3riK',
  'https://www.etix.com/ticket/p/32619116/brandy-clark-asheville',
  'https://www.axs.com/events/1123852/sabaton-tickets',
  'https://hyveetix.evenue.net/events/AXW?RSRC=WEB_PR',
  'https://www.drphillipscenter.org/show/lewis-black-rc67',
  'https://seatgeek.com/harry-styles-tickets/glendale-2027-04-03/concert/18577793',
  'https://www.ticketmaster.com/some-event/resale/event/0A0055',
  'https://www.ticketmaster.ca/event/Z7r9jZ1A7-VG7',
  'https://www.ticketmaster.com/event/Z7r9jZ1Advv4g',
  'https://travel.ticketmaster.com/en-US/event/127560094/pf?_uid=abc',
  'https://www.vipnation.com/tour_date/syd-dallas-tx-11-20-2026',
  'https://ad.doubleclick.net/ddm/clk/638366664;445198581;c;dc_transparent=1;?https://travel.ticketmaster.com/en-US/package-forward/86358015?_uid=53',
  'https://ad.doubleclick.net/ddm/clk/1;2;c;?https://www.ticketmaster.com/x/event/0B00',
  NULL]) u;
\echo G1 the event rows carry both, kept by the database; the views show them
SELECT tm_event_id, seller, channel FROM tm_discovery_event ORDER BY tm_event_id COLLATE "C" LIMIT 3;
SELECT channel, seller, sum(events) AS events FROM v_tm_discovery_channel GROUP BY 1, 2 ORDER BY 1, 2;
SELECT count(*) FILTER (WHERE seller = 'ticketmaster' AND channel = 'primary') AS tm_primary FROM v_tm_discovery_link;
SELECT has_function_privilege('anon', 'tm_link_channel(text)', 'EXECUTE'), has_function_privilege('service_role', 'tm_link_channel(text)', 'EXECUTE');

\echo G2 a Ticketmaster resale page lands as secondary; the channel view counts it apart
INSERT INTO tm_discovery_event (tm_event_id, name, url, local_date) VALUES ('Z7r9jZ1A7-VG7', 'Some Team vs Other Team', 'https://www.ticketmaster.ca/event/Z7r9jZ1A7-VG7', current_date + 3);
SELECT tm_event_id, seller, channel FROM tm_discovery_event WHERE tm_event_id LIKE 'Z7r9j%';
SELECT channel, seller, sum(events) AS events FROM v_tm_discovery_channel GROUP BY 1, 2 ORDER BY 1, 2;
