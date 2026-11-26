-- An exclude_regex token removes a title from the watch AND from the API feed
-- (mig 20261126183000). Operator 2026-11-26: "never poll or push out Crypto.com Arena VIP
-- Tours presented by Delta Air Lines".
--
-- The point under test is that exclude_regex is the one gate keep_all does NOT lift, so a
-- flagged venue is watched whole EXCEPT for excluded titles, and both arms of
-- axs_catalogue_fill honour it — so an excluded event is not merely unwatched, it is deleted
-- from the catalogue and therefore from v_primary_poll_events_feed.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by)
VALUES (940001, 'Tour Barn Arena', 0, true, true, 'scenario', 'test');
UPDATE public.axs_watch_config SET keep_regex = NULL, target_events = 50, reader = 'worker',
       exclude_regex = '(parking|vip tours|^ryman .*\mtour)';

INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, true, 'On Sale', v.title, 'Music', 940001, 'Tour Barn Arena', 'Los Angeles', 'CA',
       to_char(now() + make_interval(days => v.days), 'YYYY-MM-DD"T"HH24:MI:SS'),
       now() + make_interval(days => v.days), 'America/Los_Angeles',
       'https://www.axs.com/events/' || v.id
  FROM (VALUES (9400001,'Arena VIP Tours presented by Someone',  20),
               (9400002,'Arena VIP Tours presented by Someone',  300),
               (9400003,'A Real Concert',                        20),
               (9400004,'A Real Concert Far Out',                300),
               (9400005,'Stadium Parking Pass',                  20),
               -- the anchor trap: all four Ryman tour shapes must go, but a real concert whose
               -- title merely ENDS in Tour must stay, and so must one with Ryman later in it
               (9400006,'Ryman Guided Tour',                     21),
               (9400007,'Ryman Self-Guided Tour | Santa',        22),
               (9400008,'Ryman VIP Tour',                        23),
               (9400009,'Ryman Guided Backstage Tour',           24),
               (9400010,'Todd Rundgren: DAMNED IF I DO TOUR',    25),
               (9400011,'Christmas at the Ryman',                26)) AS v(id, title, days);

\echo '--- A. the gate: the excluded titles are refused even though the venue is keep_all'
SELECT e.axs_event_id, left(e.event_title,38) AS title,
       public.axs_watch_rule_ok(e.major_category, e.event_title, e.venue_id) AS passes
  FROM public.axs_export_event e WHERE e.venue_id=940001 ORDER BY 1;

\echo '--- B. the watch fill takes only the real near event'
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill;
SELECT source_event_id, left(name,30) AS name, watch FROM public.primary_poll_event
 WHERE source='axs' ORDER BY 1;

\echo '--- C. the catalogue fill publishes the real far-out one and NEITHER excluded title'
SELECT public.axs_catalogue_fill() AS catalogue;
SELECT source_event_id, left(name,30) AS name, watch FROM public.primary_poll_event
 WHERE source='axs' ORDER BY 1;

\echo '--- D. so nothing excluded reaches the API feed at all'
SELECT count(*) AS api_events,
       count(*) FILTER (WHERE event_id IN ('9400001','9400002','9400005')) AS excluded_in_feed
  FROM public.v_primary_poll_events_feed WHERE source='axs';

\echo '--- E. THE RETIRE PATH: an excluded title already on the list is removed, not stranded.'
\echo '---    Both a watched row and a catalogue row are planted, then the fills are re-run.'
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc,
        venue_name, ticket_url, poll_status, next_poll_at, poll_interval, watch, last_run)
VALUES ('axs','9400001','Arena VIP Tours presented by Someone',(now()+interval '20 days')::date,
        now()+interval '20 days','Tour Barn Arena','https://www.axs.com/events/9400001','ok',
        now(), interval '30 minutes', true, 'seed'),
       ('axs','9400002','Arena VIP Tours presented by Someone',(now()+interval '300 days')::date,
        now()+interval '300 days','Tour Barn Arena','https://www.axs.com/events/9400002','pending',
        now(), interval '1 hour', false, 'seed')
ON CONFLICT (source, source_event_id) DO UPDATE SET watch = EXCLUDED.watch;
SELECT count(*) FILTER (WHERE watch) AS planted_watched,
       count(*) FILTER (WHERE NOT watch) AS planted_catalogue
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id IN ('9400001','9400002');
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS refill;
SELECT public.axs_catalogue_fill() AS recatalogue;
SELECT count(*) AS excluded_rows_left FROM public.primary_poll_event
 WHERE source='axs' AND source_event_id IN ('9400001','9400002');
SELECT count(*) AS excluded_in_feed_now FROM public.v_primary_poll_events_feed
 WHERE source='axs' AND event_id IN ('9400001','9400002');

\echo '--- F. and the real events are untouched throughout'
SELECT source_event_id, left(name,30) AS name, watch FROM public.primary_poll_event
 WHERE source='axs' ORDER BY 1;
