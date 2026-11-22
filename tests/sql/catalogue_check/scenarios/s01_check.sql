-- catalogue_check: the stored answer, the live answer per marketplace, every verdict, the guards.
-- Fixed timestamps (UTC) so the output is stable; ms, checked_at and age_hours are left out of what is printed.
\set QUIET 1
\pset footer off
\pset format aligned
SET client_min_messages = warning;
SET timezone = 'UTC';

-- the answer without its clock-dependent parts
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT jsonb_pretty(j - 'checked_at' - 'age_hours' #- '{live,ms}' #- '{live,last_checked_at}' #- '{live,last,ms}') $$;
-- the error a call raises, as text
CREATE FUNCTION err_(q text) RETURNS text LANGUAGE plpgsql AS $$ BEGIN EXECUTE q; RETURN 'no error'; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $$;
-- one line: verdict, id, where the id came from, whether the marketplace was asked and what it answered
CREATE FUNCTION line_(j jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT concat_ws(' | ', j->>'marketplace', j->>'verdict', 'id=' || coalesce(j->>'source_event_id', '-'),
                   'from=' || coalesce(j->>'id_from', '-'), 'tevo=' || coalesce(j->>'tevo_event_id', '-'),
                   'asked=' || coalesce(j#>>'{live,asked}', '-'), 'http=' || coalesce(j#>>'{live,http}', '-'),
                   'reason=' || coalesce(j#>>'{live,reason}', '-'), 'differs=' || coalesce(j->>'differs', '-')) $$;

-- ───────── what we hold ─────────
INSERT INTO public.events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, last_seen) VALUES
  (1, 'Billy Joel',                        '2027-03-01T20:00:00-05:00', 'shown', 100, 'Madison Square Garden', 'New York, NY', '2026-11-22 10:00+00'),
  (2, 'New York Knicks vs Boston Celtics', '2027-03-05T19:30:00-05:00', 'shown', 100, 'Madison Square Garden', 'New York, NY', '2026-11-22 10:00+00'),
  (3, 'Hamilton',                          '2027-03-07T14:00:00-05:00', 'shown', 300, 'Richard Rodgers Theatre', 'New York, NY', '2026-11-22 10:00+00');
INSERT INTO public.aq_event_map (aq_short_event_id, aq_source, tevo_event_id, sg_event_id, sh_event_id, vivid_event_id, gotickets_event_id, tp_event_id, axs_event_id) VALUES
  ('AAAAAA1', 'aq_curated', 1, 5001, 6001, 7001, 8001, 9001, '4001'),
  ('AAAAAA2', 'aq_curated', 2, NULL, NULL, NULL, 8002, NULL, NULL),
  ('SYS-dup', 'system_seed', 2, NULL, NULL, NULL, 8099, NULL, NULL);
INSERT INTO public.event_xref (tevo_event_id, espn_event_id, espn_league) VALUES (2, '401700001', 'nba');

INSERT INTO public.tickpick_catalog_event (tp_event_id, name, status, event_local, event_utc, venue_name, venue_city, venue_state, last_seen_at, tevo_event_id, tevo_match_method) VALUES
  (9001, 'Billy Joel',       'scheduled', '2027-03-01 20:00', '2027-03-02 01:00+00', 'Madison Square Garden', 'New York', 'NY', '2026-11-22 09:41+00', 1, 'hub_identity'),
  (9002, 'Knicks vs Celtics','scheduled', '2027-03-05 19:30', '2027-03-06 00:30+00', 'Madison Square Garden', 'New York', 'NY', '2026-11-22 09:41+00', 2, 'venue_day_name'),
  (9003, 'A Cancelled Show', 'scheduled', '2027-04-01 20:00', '2027-04-02 00:00+00', 'Some Hall',             'Albany',   'NY', '2026-11-20 09:41+00', NULL, NULL),
  (9004, 'Hamilton',         'scheduled', '2027-03-07 14:00', '2027-03-07 19:00+00', 'Richard Rodgers Theatre','New York','NY', '2026-11-22 09:41+00', 2, 'venue_day_name');
INSERT INTO public.gotickets_event (gt_event_id, name, venue_name, venue_city, venue_state, event_time_utc, status, tevo_event_id, mapped_via, updated_at) VALUES
  (8001, 'Billy Joel', 'Madison Square Garden', 'New York', 'NY', '2027-03-02 01:00+00', 'AS_SCHEDULED', 1, 'venue_day_name', '2026-11-22 08:45+00');
INSERT INTO public.vivid_catalog_event (vivid_event_id, name, event_local, venue_name, venue_city, venue_state, last_seen_at, tevo_event_id, tevo_match_method) VALUES
  (7001, 'Billy Joel', '2027-03-01 20:00', 'Madison Square Garden', 'New York', 'NY', '2026-11-22 18:00+00', 1, 'hub_identity');
INSERT INTO public.vivid_catalog_sync VALUES (1, '2026-11-22 17:39+00', '2026-11-22 18:28+00');
INSERT INTO public.sg_events_canonical (sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_venue_name, sg_venue_city, sg_venue_state, tevo_event_id, match_method, updated_at) VALUES
  (5001, 'Billy Joel', '2027-03-02', '2027-03-02 01:00+00', 'Madison Square Garden', 'New York', 'NY', 1, 'matcher_v3', '2026-11-22 07:00+00');
INSERT INTO public.axs_export_event (axs_event_id, status, event_title, venue_name, venue_city, venue_state, event_date_local, last_seen_utc, tevo_event_id, match_method) VALUES
  (4001, 'onsale', 'Billy Joel', 'Madison Square Garden', 'New York', 'NY', '2027-03-01T20:00:00', '2026-11-22 06:00+00', 1, 'venue_date_time');
INSERT INTO public.mlb_ticket_game (schedule_id, home_name, away_name, venue_name, venue_city, game_time_local, game_time_utc, status, last_seen_at, tevo_event_id, tevo_match_method) VALUES
  (777001, 'Miami Marlins', 'Pittsburgh Pirates', 'loanDepot park', 'Miami', '2027-07-04 13:40', '2027-07-04 17:40+00', 'Scheduled', '2026-11-22 19:00+00', 3, 'teams_day');

-- ───────── what the marketplaces answer ─────────
INSERT INTO public.stub_http_page (match, status, body) VALUES
  ('api.tickpick.com/1.0/catalog/events/9001', 200, '{"event_id":"9001","name":"Billy Joel","status":"scheduled","event_date":"2027-03-01T20:00:00","event_date_utc":"2027-03-02T01:00:00Z","venue":{"venue_id":1,"name":"Madison Square Garden","city":"New York","state":"NY","country":"US"}}'),
  -- moved a day, renamed, and folded into another event
  ('api.tickpick.com/1.0/catalog/events/9002', 200, '{"event_id":"9002","name":"New York Knicks vs. Boston Celtics","status":"rescheduled","event_date":"2027-03-06T19:30:00","event_date_utc":"2027-03-07T00:30:00Z","merged_into":"9555","venue":{"venue_id":1,"name":"Madison  Square Garden","city":"New York","state":"NY","country":"US"}}'),
  -- 9003: no page → 404 (we hold it, TickPick no longer does)
  ('api.tickpick.com/1.0/catalog/events/9500', 200, '{"event_id":"9500","name":"Brand New Show","status":"scheduled","event_date":"2027-05-01T20:00:00","event_date_utc":"2027-05-02T00:00:00Z","venue":{"venue_id":2,"name":"New Room","city":"Boston","state":"MA","country":"US"}}'),
  ('sc.gotickets.com/rest/events/8001', 429, '{"message":"Too many requests."}'),
  ('sc.gotickets.com/rest/events/8002', 200, '{"id":8002,"name":"New York Knicks vs Boston Celtics","venueName":"Madison Square Garden","venueCity":"New York","venueState":"NY","eventTimeLocal":"2027-03-05T19:30:00","eventTimeUtc":"2027-03-06T00:30:00","status":"AS_SCHEDULED"}'),
  ('api.ticketevolution.com/v9/events/1', 200, '{"id":1,"name":"Billy Joel","state":"shown","occurs_at":"2027-03-01T20:00:00Z","occurs_at_local":"2027-03-01T20:00:00-05:00","venue":{"id":100,"name":"Madison Square Garden","address":{"locality":"New York","region":"NY"}}}'),
  ('api.ticketevolution.com/v9/events/3', 500, 'upstream error'),
  ('app.ticketmaster.com/discovery/v2/events/vvG1abcDEF123.json', 200, '{"id":"vvG1abcDEF123","name":"Billy Joel","dates":{"start":{"localDate":"2027-03-01","localTime":"20:00:00","dateTime":"2027-03-02T01:00:00Z"},"status":{"code":"onsale"}},"_embedded":{"venues":[{"id":"KovZ1","name":"Madison Square Garden","city":{"name":"New York"},"state":{"stateCode":"NY"}}]}}');

\echo == tickpick by its own id: listed, the marketplace agrees with our row
SELECT out_(public.catalogue_check('tickpick', '9001'));

\echo == tickpick: listed, but changed — a new name, a day later, rescheduled, folded into another event (extra spaces in the venue are not a change)
SELECT out_(public.catalogue_check('tp', '9002')) ;

\echo == the verdicts, one line each
SELECT line_(public.catalogue_check('tickpick', '9003'))            AS "we hold it, TickPick answers 404";
SELECT line_(public.catalogue_check('tickpick', '9500'))            AS "TickPick lists it, we do not hold it yet";
SELECT line_(public.catalogue_check('tickpick', '9999'))            AS "neither";
SELECT line_(public.catalogue_check('gotickets', '8001'))           AS "a 429 is not an answer: stored only";
SELECT line_(public.catalogue_check('gt', '8002'))                  AS "GoTickets lists it; we hold only the hub id";
SELECT line_(public.catalogue_check('evo', NULL, 1))                AS "EVO by its own id";
SELECT line_(public.catalogue_check('tevo', '3'))                   AS "EVO answers 500: stored only";
SELECT line_(public.catalogue_check('evo', '424242'))               AS "EVO has no such event";

\echo == asked by EVO id alone: where the marketplace id comes from
SELECT line_(public.catalogue_check('tickpick', NULL, 1, false))    AS "its catalogue";
SELECT line_(public.catalogue_check('gotickets', NULL, 2, false))   AS "the hub (curated row first)";
SELECT line_(public.catalogue_check('seatgeek', NULL, 1, false))    AS "seatgeek";
SELECT line_(public.catalogue_check('axs', NULL, 1, false))         AS "axs (text id in the hub)";
SELECT line_(public.catalogue_check('mlb', NULL, 3, false))         AS "mlb";
SELECT line_(public.catalogue_check('vivid', NULL, 3, false))       AS "no Vivid id for that event";
SELECT j->>'other_ids_for_event' AS other_ids, line_(j) AS "two TickPick rows map to EVO 2: the freshest is taken"
  FROM (SELECT public.catalogue_check('tickpick', NULL, 2, false) j) z;

\echo == marketplaces that cannot be asked for one event: the stored answer, and why
SELECT out_(public.catalogue_check('vivid', '7001'));
SELECT line_(public.catalogue_check('seatgeek', '5001'))            AS seatgeek;
SELECT line_(public.catalogue_check('axs', '4001'))                 AS axs;
SELECT line_(public.catalogue_check('mlb', '777001'))               AS mlb;
SELECT line_(public.catalogue_check('stubhub', '6001'))             AS "stubhub: the hub carries the id";
SELECT line_(public.catalogue_check('stubhub', '6999'))             AS "stubhub: unknown id";
SELECT line_(public.catalogue_check('seatdata', NULL, 1))           AS "seatdata: no id for the event";

\echo == both ids given: does our mapping agree
SELECT j->>'mapping_agrees' AS agrees, line_(j) FROM (SELECT public.catalogue_check('tickpick', '9001', 1, false) j) z;
SELECT j->>'mapping_agrees' AS agrees, line_(j) FROM (SELECT public.catalogue_check('tickpick', '9001', 2, false) j) z;

\echo == asked twice inside the interval: the second is not sent, the first answer rides along
SELECT line_(j) AS second_call, j#>>'{live,last,http}' AS last_http, j#>>'{live,last,found}' AS last_found
  FROM (SELECT public.catalogue_check('tickpick', '9001') j) z;
SELECT line_(public.catalogue_check('tickpick', '9001', NULL, true, interval '0')) AS "interval 0: sent again";

\echo == Ticketmaster and ESPN before their tables exist (main without PR #1156)
SELECT line_(public.catalogue_check('ticketmaster', 'vvG1abcDEF123', NULL, false)) AS tm;
SELECT line_(public.catalogue_check('tm', NULL, 1, false))                         AS tm_by_evo;
SELECT line_(public.catalogue_check('espn', NULL, 2, false))                       AS "espn: event_xref still answers";

\echo == ...and once they exist
CREATE TABLE public.tm_discovery_event (tm_event_id text PRIMARY KEY, name text, local_date date, local_time time, start_utc timestamptz, status_code text,
                                        venue_name text, venue_city text, venue_state text, last_seen_at timestamptz, tevo_event_id bigint, tevo_match_method text);
INSERT INTO public.tm_discovery_event VALUES ('vvG1abcDEF123', 'Billy Joel', '2027-03-01', '20:00', '2027-03-02 01:00+00', 'onsale',
                                              'Madison Square Garden', 'New York', 'NY', '2026-11-22 12:00+00', 1, 'venue_day_name');
CREATE TABLE public.tm_discovery_quota (day date PRIMARY KEY, calls int NOT NULL DEFAULT 0, cap int NOT NULL DEFAULT 2);
CREATE FUNCTION public.tm_discovery_call_allowed(p_kind text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_ok boolean;
BEGIN
  INSERT INTO public.tm_discovery_quota (day) VALUES (current_date) ON CONFLICT (day) DO NOTHING;
  UPDATE public.tm_discovery_quota q SET calls = q.calls + 1 WHERE q.day = current_date AND q.calls < q.cap RETURNING true INTO v_ok;
  RETURN coalesce(v_ok, false);
END $$;
CREATE TABLE public.espn_ticket_game (espn_event_id text PRIMARY KEY, name text, venue_name text, venue_city text, venue_state text, game_at_utc timestamptz,
                                      status text, last_seen_at timestamptz, tevo_event_id bigint, tevo_match_method text);
INSERT INTO public.espn_ticket_game VALUES ('401700001', 'Boston Celtics at New York Knicks', 'Madison Square Garden', 'New York', 'NY', '2027-03-06 00:30+00',
                                            'STATUS_SCHEDULED', '2026-11-22 19:20+00', 2, 'teams_day');
SELECT out_(public.catalogue_check('ticketmaster', NULL, 1));
SELECT line_(public.catalogue_check('tm', 'vvG1abcDEF123', NULL, true, interval '0')) AS "second read: the budget's last call";
SELECT line_(public.catalogue_check('tm', 'vvG1abcDEF123', NULL, true, interval '0')) AS "third read: the day's budget is spent";
SELECT calls, cap FROM public.tm_discovery_quota;
SELECT line_(public.catalogue_check('espn', NULL, 2))                              AS espn;

\echo == one EVO event across every marketplace (stored answers)
SELECT marketplace, verdict, source_event_id FROM public.catalogue_check_all(1);

\echo == guards
SELECT line_(public.catalogue_check('tickpick', '9001; DROP TABLE x'))             AS "an id that is not an id is never sent";
SELECT line_(public.catalogue_check('ticketmaster', 'abc/../../x?y=1'))            AS "nor a Ticketmaster one";
SELECT err_($$SELECT public.catalogue_check('craigslist', '1')$$) AS "an unknown marketplace";
SELECT err_($$SELECT public.catalogue_check('tickpick')$$)        AS "no id at all";
SELECT err_($$SELECT * FROM public.catalogue_check_all(NULL)$$)   AS "catalogue_check_all without an event";
SELECT r AS role, has_function_privilege(r, 'public.catalogue_check(text,text,bigint,boolean,interval)', 'EXECUTE') AS may_call,
       has_function_privilege(r, 'public.catalogue_check_live(text,text)', 'EXECUTE') AS may_call_live,
       has_table_privilege(r, 'public.catalogue_check_log', 'SELECT') AS may_read_log
  FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r;

\echo == every request that left: GET only, one per live check, never for a refused id
SELECT method, regexp_replace(uri, 'apikey=.*$', 'apikey=…') AS uri, headers FROM public.stub_http_log ORDER BY id;

\echo == the log: one row per call
SELECT marketplace, count(*) AS calls, count(*) FILTER (WHERE live_asked) AS asked_live,
       string_agg(DISTINCT verdict, ', ' ORDER BY verdict) AS verdicts
  FROM public.catalogue_check_log GROUP BY 1 ORDER BY 1;
SELECT count(*) AS catalogue_rows_unchanged FROM public.tickpick_catalog_event;
