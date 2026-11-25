-- An AXS event leaves the watch six hours before it starts, not six hours after (mig 20261125150000):
-- stop_before_start governs the retire, the pick and what the worker is handed.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the default'
SELECT stop_before_start FROM public.axs_watch_config;

-- one venue of ten places; the build's own first fill, against an empty export, is forgotten
DELETE FROM public.axs_watch_venue;
DELETE FROM public.axs_watch_audit;
DELETE FROM public.primary_poll_event WHERE source = 'axs';
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled) VALUES (1, 'Big Arena', 10, true);
UPDATE public.axs_watch_config SET target_events = 10, watch_from = current_date - 1, backfill = false,
       reader = 'worker';   -- axs_watch_next only hands out events to the worker-side reader

INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, status, event_title, major_category,
       venue_id, venue_name, venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, 'axs_primary', 'axs', true, 'Buy Tickets', v.title, 'Music', 1, 'Big Arena', 'Los Angeles', 'CA',
       to_char(now() + v.off, 'YYYY-MM-DD') || 'T20:00:00', now() + v.off, 'America/Los_Angeles',
       'https://www.axs.com/events/' || v.id || '/tickets'
  FROM (VALUES (201, 'Started An Hour Ago',   interval '-1 hour'),
               (202, 'Starts In Two Hours',   interval '2 hours'),
               (203, 'Starts In Five Hours',  interval '5 hours 30 minutes'),
               (204, 'Starts In Seven Hours', interval '7 hours'),
               (205, 'Starts In Two Days',    interval '2 days'),
               (206, 'Starts In A Month',     interval '30 days')) v(id, title, off);

\echo '--- B. the fill picks only events further out than stop_before_start (6h): 204, 205, 206'
SELECT (public.axs_watch_fill()) - 'run' AS fill;
SELECT t.source_event_id, t.name, t.start_utc > now() + interval '6 hours' AS beyond_window
  FROM public.primary_poll_event t WHERE t.source = 'axs' ORDER BY t.start_utc;

\echo '--- C. the worker is handed only those, and never one inside the window'
SELECT jsonb_agg(x->>'id' ORDER BY x->>'id') AS handed
  FROM jsonb_array_elements((public.axs_watch_next(20))->'events') x;

\echo '--- D. time passes: 204 is now inside the window, so the worker stops being handed it'
UPDATE public.axs_export_event SET event_date_utc = now() + interval '3 hours' WHERE axs_event_id = 204;
UPDATE public.primary_poll_event SET start_utc = now() + interval '3 hours' WHERE source = 'axs' AND source_event_id = '204';
SELECT jsonb_agg(x->>'id' ORDER BY x->>'id') AS handed_now
  FROM jsonb_array_elements((public.axs_watch_next(20))->'events') x;

\echo '--- E. the next fill retires it with starts_soon, and does not pick it again'
SELECT (public.axs_watch_fill()) - 'run' AS fill_again;
SELECT a.action, a.axs_event_id, a.note FROM public.axs_watch_audit a
 WHERE a.note = 'starts_soon' ORDER BY a.axs_event_id;
SELECT t.source_event_id, t.name FROM public.primary_poll_event t WHERE t.source = 'axs' ORDER BY t.start_utc;

\echo '--- F. stop_before_start = 0 keeps an event until it starts (the old reads-stop-at-tipoff behaviour)'
UPDATE public.axs_watch_config SET stop_before_start = interval '0';
SELECT (public.axs_watch_fill()) - 'run' AS fill_zero;
SELECT t.source_event_id, t.name FROM public.primary_poll_event t WHERE t.source = 'axs' ORDER BY t.start_utc;
\echo '--- and primary_poll_ended still stops the reads at the start, so 201 is not handed out'
SELECT jsonb_agg(x->>'id' ORDER BY x->>'id') AS handed_zero
  FROM jsonb_array_elements((public.axs_watch_next(20))->'events') x;
