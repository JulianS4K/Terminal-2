-- The places a venue cannot fill go to the other venues' events, and come back when it can (mig 20261125023030).
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL;  -- these fixtures are not the operator's three teams (mig 20261125232000)

-- two venues of three places each, a list of six; the build's own first fill, against an empty export, is forgotten
DELETE FROM public.axs_watch_venue;
DELETE FROM public.axs_watch_audit;
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled) VALUES (1, 'Arena', 3, true), (2, 'Stadium', 3, true), (3, 'Closed Hall', 5, false);
UPDATE public.axs_watch_config SET target_events = 6, watch_from = current_date + 1;
INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, status, event_title, major_category, venue_id, venue_name, venue_city, venue_state,
                                     event_date_local, event_date_utc, event_timezone, event_url, onsale_utc)
SELECT v.id, 'axs_primary', 'axs', true, v.status, v.title, 'Music', v.venue, CASE v.venue WHEN 1 THEN 'Arena' WHEN 2 THEN 'Stadium' ELSE 'Closed Hall' END, 'Houston', 'TX',
       to_char(now() + v.days * interval '1 day', 'YYYY-MM-DD') || 'T20:00:00', now() + v.days * interval '1 day', 'America/Chicago',
       'https://www.axs.com/events/' || v.id || '/tickets', NULL::timestamptz
  FROM (VALUES (11, 1, 'Arena Night 1', 'Buy Tickets', 10), (12, 1, 'Arena Night 2', 'Buy Tickets', 11), (13, 1, 'Arena Night 3', 'Buy Tickets', 12),
               (14, 1, 'Arena Night 4', 'Buy Tickets', 13), (15, 1, 'Arena Night 5', 'Buy Tickets', 14),
               (21, 2, 'Stadium Show 1', 'Coming Soon', 20), (22, 2, 'Stadium Show 2', 'Coming Soon', 21), (23, 2, 'Stadium Show 3', 'Coming Soon', 22),
               (31, 3, 'Closed Hall Show', 'Buy Tickets', 5)) v(id, venue, title, status, days);

\echo '--- A. with the backfill off, the Stadium''s three places stay empty: nothing of its is on sale'
UPDATE public.axs_watch_config SET backfill = false;
SELECT (public.axs_watch_fill(false)) - 'run' AS dry_run_off;

\echo '--- B. with it on, the Arena''s next events take them, soonest first; a venue that is switched off gives none; the dry run says the same as the fill'
UPDATE public.axs_watch_config SET backfill = true;
SELECT (public.axs_watch_fill(false)) - 'run' AS dry_run;
SELECT (public.axs_watch_fill(true)) - 'run' AS fill;
SELECT source_event_id AS id, name FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;
SELECT action, axs_event_id AS id, venue, regexp_replace(note, '[0-9]{4}-[0-9]{2}-[0-9]{2}T', 'DATE ') AS note FROM public.axs_watch_audit ORDER BY action, id, venue;

\echo '--- C. the night after, nothing moves'
SELECT (public.axs_watch_fill(true)) - 'run' AS fill_again;

\echo '--- D. the Stadium goes on sale: its own three come in, and the two borrowed places are given back, the furthest event first'
DELETE FROM public.axs_watch_audit;
UPDATE public.axs_export_event SET status = 'Buy Tickets' WHERE venue_id = 2;
SELECT (public.axs_watch_fill(false)) - 'run' AS dry_run;
SELECT (public.axs_watch_fill(true)) - 'run' AS fill;
SELECT source_event_id AS id, name FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;
SELECT action, axs_event_id AS id, venue, regexp_replace(note, '[0-9]{4}-[0-9]{2}-[0-9]{2}T', 'DATE ') AS note FROM public.axs_watch_audit ORDER BY action, id, venue;

\echo '--- E. a bigger list borrows again; when the Stadium gains one place of its own, one borrowed place is given back'
UPDATE public.axs_watch_config SET target_events = 8;
SELECT (public.axs_watch_fill(true)) - 'run' AS bigger_list;
UPDATE public.axs_watch_venue SET quota = 4 WHERE axs_venue_id = 2;
INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, status, event_title, major_category, venue_id, venue_name, venue_city, venue_state,
                                     event_date_local, event_date_utc, event_timezone, event_url)
VALUES (24, 'axs_primary', 'axs', true, 'Buy Tickets', 'Stadium Show 4', 'Music', 2, 'Stadium', 'Houston', 'TX',
        to_char(now() + interval '23 days', 'YYYY-MM-DD') || 'T20:00:00', now() + interval '23 days', 'America/Chicago', 'https://www.axs.com/events/24/tickets');
SELECT (public.axs_watch_fill(true)) - 'run' AS one_given_back;
SELECT source_event_id AS id, name FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;

\echo '--- F. a quota lowered turns a venue''s furthest events into borrowed places, kept until another venue needs them'
UPDATE public.axs_watch_venue SET quota = 2 WHERE axs_venue_id = 2;
SELECT (public.axs_watch_fill(true)) - 'run' AS quota_lowered;
SELECT count(*) AS watched, count(*) FILTER (WHERE venue_name = 'Stadium') AS at_the_stadium FROM public.primary_poll_event WHERE source = 'axs';
