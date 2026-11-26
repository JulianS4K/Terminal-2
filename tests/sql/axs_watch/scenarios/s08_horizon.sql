-- A place is not spent more than watch_until_days out (mig 20261125173500, operator "180 days ceiling on
-- events"): the fill neither picks nor keeps an event beyond the horizon, and NULL turns the ceiling off.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL;  -- these fixtures are not the operator's three teams (mig 20261125232000)

\echo '--- A. the default'
SELECT watch_until_days, stop_before_start FROM public.axs_watch_config;

DELETE FROM public.axs_watch_venue;
DELETE FROM public.axs_watch_audit;
DELETE FROM public.primary_poll_event WHERE source = 'axs';
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled) VALUES (1, 'Big Arena', 10, true);
UPDATE public.axs_watch_config SET target_events = 10, watch_from = current_date - 1, backfill = false,
       reader = 'worker';

INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, status, event_title, major_category,
       venue_id, venue_name, venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, 'axs_primary', 'axs', true, 'Buy Tickets', v.title, 'Music', 1, 'Big Arena', 'Los Angeles', 'CA',
       to_char(now() + v.off, 'YYYY-MM-DD') || 'T20:00:00', now() + v.off, 'America/Los_Angeles',
       'https://www.axs.com/events/' || v.id || '/tickets'
  FROM (VALUES (801, 'In Thirty Days',         interval '30 days'),
               (802, 'In A Hundred Days',      interval '100 days'),
               (803, 'Just Inside The Ceiling', interval '179 days'),
               (804, 'Just Outside It',        interval '181 days'),
               (805, 'A Year Out',             interval '365 days')) v(id, title, off);

\echo '--- B. only the three inside 180 days are picked'
SELECT (public.axs_watch_fill()) - 'run' AS fill;
SELECT t.source_event_id, t.name, t.event_date - current_date AS days_out
  FROM public.primary_poll_event t WHERE t.source='axs' ORDER BY t.event_date;

\echo '--- C. an event pushed beyond the ceiling is retired with beyond_horizon'
UPDATE public.axs_export_event SET event_date_local = to_char(now() + interval '200 days', 'YYYY-MM-DD') || 'T20:00:00',
       event_date_utc = now() + interval '200 days' WHERE axs_event_id = 802;
UPDATE public.primary_poll_event SET event_date = (now() + interval '200 days')::date,
       start_utc = now() + interval '200 days' WHERE source='axs' AND source_event_id = '802';
SELECT (public.axs_watch_fill()) - 'run' AS fill_again;
SELECT a.action, a.axs_event_id, a.note FROM public.axs_watch_audit a
 WHERE a.note = 'beyond_horizon' ORDER BY a.axs_event_id;
SELECT t.source_event_id, t.event_date - current_date AS days_out
  FROM public.primary_poll_event t WHERE t.source='axs' ORDER BY t.event_date;

\echo '--- D. watch_until_days = NULL turns the ceiling off and the far events come back'
UPDATE public.axs_watch_config SET watch_until_days = NULL;
SELECT (public.axs_watch_fill()) - 'run' AS fill_no_ceiling;
SELECT t.source_event_id, t.event_date - current_date AS days_out
  FROM public.primary_poll_event t WHERE t.source='axs' ORDER BY t.event_date;
