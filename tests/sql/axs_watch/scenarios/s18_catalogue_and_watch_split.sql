-- The API lists every event at a whole venue; we READ only target_events of them
-- (mig 20261126060000). primary_poll_event.watch separates the two sets, and the feed
-- renders a catalogue-only row as listings_withheld = 'not_polled' — a value the view
-- already defined before anything deliberately used it.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

-- a whole venue of our own, and a venue the config regexes govern
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by)
VALUES (910001, 'Whole House', 0, true, true,  'scenario', 'test'),
       (910002, 'Rule House',  0, true, false, 'scenario', 'test');
UPDATE public.axs_watch_config SET keep_regex = NULL, target_events = 3, reader = 'worker';

\echo '--- A. the flag exists and defaults to true, so no other source changes'
SELECT column_default, is_nullable FROM information_schema.columns
 WHERE table_name = 'primary_poll_event' AND column_name = 'watch';
SELECT catalogue_until_days > watch_until_days AS catalogue_reaches_further
  FROM public.axs_watch_config;

-- six events at the whole venue: 4 inside the watch horizon, 1 beyond it, 1 not on sale
INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url, onsale_utc)
SELECT v.id, true, v.st, v.title, 'Music', v.venue, 
       CASE v.venue WHEN 910001 THEN 'Whole House' ELSE 'Rule House' END,
       'Denver', 'CO',
       to_char(now() + make_interval(days => v.days), 'YYYY-MM-DD"T"HH24:MI:SS'),
       now() + make_interval(days => v.days), 'America/Denver',
       'https://www.axs.com/events/' || v.id, v.onsale
  FROM (VALUES
     (9200001, 'On Sale',     'Soonest',        910001::bigint, 10,  NULL::timestamptz),
     (9200002, 'On Sale',     'Second',         910001,         20,  NULL),
     (9200003, 'On Sale',     'Third',          910001,         30,  NULL),
     (9200004, 'On Sale',     'Fourth',         910001,         40,  NULL),
     (9200005, 'On Sale',     'Beyond Horizon', 910001,         300, NULL),
     (9200006, 'Coming Soon', 'Not On Sale Yet',910001,         50,  now() + interval '20 days'),
     (9200007, 'On Sale',     'At Rule House',  910002,         15,  NULL)
   ) AS v(id, st, title, venue, days, onsale);

\echo '--- B. the fill reads target_events (3) and publishes the rest as catalogue-only'
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill;
SELECT source_event_id AS id, left(name,16) AS name, watch, venue_name
  FROM public.primary_poll_event WHERE source='axs' ORDER BY watch DESC, event_date;

\echo '--- C. the API sees ALL of them; only the watched ones can carry listings'
SELECT event_id, left(name,16) AS name, listings_available, listings_withheld
  FROM public.v_primary_poll_events_feed WHERE source='axs' ORDER BY event_id;

\echo '--- D. every selector skips a catalogue row. Without all four it is read anyway,'
\echo '       because primary_poll_due counts a NULL next_poll_at as due.'
SELECT public.primary_poll_due('axs', (SELECT jsonb_agg(source_event_id)
         FROM public.primary_poll_event WHERE source='axs')) AS due_ids;
-- the worker's batch must contain the watched ids and nothing else
SELECT jsonb_array_length(b->'events') AS worker_batch_size,
       (SELECT coalesce(string_agg(x->>'id', ',' ORDER BY x->>'id'), '(none)')
          FROM jsonb_array_elements(b->'events') x) AS batch_ids,
       b->>'reason' AS reason
  FROM (SELECT public.axs_watch_next(50, 'w-s18') AS b) q;
SELECT (public.axs_queue_fill())->'enqueued' AS queue_enqueued_with_queue_off;

\echo '--- E. a catalogue row is PROMOTED when the watch set grows (not skipped by DO NOTHING)'
UPDATE public.axs_watch_config SET target_events = 5;
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_with_more_room;
SELECT count(*) FILTER (WHERE watch) AS watched,
       count(*) FILTER (WHERE NOT watch) AS catalogue_only
  FROM public.primary_poll_event WHERE source='axs';

\echo '--- F. shrinking the list DEMOTES the furthest — it stays in the feed, stops costing'
UPDATE public.axs_watch_config SET target_events = 2;
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_shrunk;
SELECT count(*) FILTER (WHERE watch) AS watched,
       count(*) FILTER (WHERE NOT watch) AS catalogue_only,
       count(*) AS still_in_the_feed
  FROM public.primary_poll_event WHERE source='axs';
SELECT note, count(*) FROM public.axs_watch_audit
 WHERE note IN ('over_target_events') GROUP BY 1;

\echo '--- G. un-flagging the venue drops its catalogue rows (it is no longer watched whole)'
UPDATE public.axs_watch_venue SET keep_all = false WHERE axs_venue_id = 910001;
SELECT (public.axs_catalogue_fill()) AS catalogue_after_unflagging;

\echo '--- H. a never-read catalogue row has spent no credit'
SELECT count(*) AS reads_made FROM public.axs_watch_poll
 WHERE axs_event_id LIKE '92000%';
