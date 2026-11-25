-- An event that is not on sale yet has no place in the list (mig 20261125013030): the fill retires a watched event
-- whose last read said so, does not pick one for not_on_sale_recheck after such a read, nor one the export dates
-- on sale later under a Coming Soon label; a sold-out show stays; after the recheck time the event is tried again.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. what says an event is not on sale: the read''s answer; "no tickets available" only under a Coming Soon label'
SELECT c.n, c.outcome, c.error, c.status, public.axs_watch_not_on_sale(c.outcome, c.error, c.status) AS not_on_sale
  FROM (VALUES (1, 'unparsed', 'Tickets for this event are not currently on sale.', 'Coming Soon'),
               (2, 'unparsed', 'Tickets for this event are not on sale yet.', 'Buy Tickets'),
               (3, 'unparsed', 'No tickets are currently available for this event.', 'Coming Soon'),
               (4, 'unparsed', 'No tickets are currently available for this event.', 'Buy Tickets'),
               (5, 'ok', NULL, 'Coming Soon'),
               (6, 'empty', NULL, 'Coming Soon'),
               (7, 'upstream_error', 'HTTP 429 from TicketsData', 'Coming Soon'),
               (8, NULL, NULL, NULL)) c(n, outcome, error, status)
 ORDER BY c.n;

-- one venue of six places; the build's own first fill, against an empty export, is forgotten
DELETE FROM public.axs_watch_venue;
DELETE FROM public.axs_watch_audit;
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled) VALUES (1, 'Big Arena', 6, true);
UPDATE public.axs_watch_config SET target_events = 10, watch_from = current_date + 1;
INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, status, event_title, major_category, venue_id, venue_name, venue_city, venue_state,
                                     event_date_local, event_date_utc, event_timezone, event_url, onsale_utc)
SELECT v.id, 'axs_primary', 'axs', true, v.status, v.title, 'Music', 1, 'Big Arena', 'Los Angeles', 'CA',
       to_char(now() + v.days * interval '1 day', 'YYYY-MM-DD') || 'T20:00:00', now() + v.days * interval '1 day', 'America/Los_Angeles',
       'https://www.axs.com/events/' || v.id || '/tickets', v.onsale
  FROM (VALUES (101, 'On Sale Show',                 'Buy Tickets', 10, NULL::timestamptz),
               (102, 'Read Says Not On Sale',        'Coming Soon', 11, NULL),
               (103, 'Coming Soon But Has Tickets',  'Coming Soon', 12, NULL),
               (104, 'Sold Out Show',                'Buy Tickets', 13, NULL),
               (105, 'No Tickets Under Coming Soon', 'Coming Soon', 14, NULL),
               (106, 'On Sale Next Month',           'Coming Soon', 15, now() + interval '30 days'),
               (107, 'Presale Open, Sale Later',     'Buy Presale', 16, now() + interval '5 days'),
               (108, 'Next In Line',                 'Buy Tickets', 17, NULL),
               (109, 'Not On Sale A Week Ago',       'Coming Soon', 18, NULL),
               (110, 'Further Out',                  'Buy Tickets', 40, NULL)) v(id, title, status, days, onsale);

\echo '--- B. the first fill: six places, soonest first; the event the export dates on sale next month is passed over, the presale one is not'
SELECT (public.axs_watch_fill(true)) - 'run' AS first_fill;
SELECT source_event_id AS id, name FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;

\echo '--- C. the reads come in; the next fill retires the two that are not on sale and gives their places to the next events, not to the one read as not on sale two days ago'
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, error, listings) VALUES
  (1, '101', now() - interval '3 hours', now() - interval '3 hours', 200, 'ok', NULL, 40),
  (2, '102', now() - interval '9 hours', now() - interval '9 hours', 200, 'ok', NULL, 3),      -- an older good read does not count: the last one does
  (3, '102', now() - interval '3 hours', now() - interval '3 hours', 200, 'unparsed', 'Tickets for this event are not currently on sale.', 0),
  (4, '103', now() - interval '3 hours', now() - interval '3 hours', 200, 'ok', NULL, 12),
  (5, '104', now() - interval '3 hours', now() - interval '3 hours', 200, 'unparsed', 'No tickets are currently available for this event.', 0),
  (6, '105', now() - interval '3 hours', now() - interval '3 hours', 200, 'unparsed', 'No tickets are currently available for this event.', 0),
  (7, '107', now() - interval '3 hours', now() - interval '3 hours', 200, 'ok', NULL, 8),
  (8, '109', now() - interval '2 days',  now() - interval '2 days',  200, 'unparsed', 'Tickets for this event are not on sale yet.', 0);
SELECT (public.axs_watch_fill(false)) - 'run' AS dry_run;
SELECT (public.axs_watch_fill(true)) - 'run' AS second_fill;
SELECT source_event_id AS id, name FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;
SELECT action, axs_event_id AS id, regexp_replace(note, '^[0-9]{4}-[0-9]{2}-[0-9]{2}T', 'DATE ') AS note
  FROM public.axs_watch_audit WHERE at >= (SELECT max(at) FROM public.axs_watch_audit) ORDER BY action, id;

\echo '--- D. the night after: nothing moves; the retired events are not picked again while their last read is within the recheck time'
SELECT (public.axs_watch_fill(true)) - 'run' AS third_fill;

\echo '--- E. past the recheck time an event is tried once more: the one read as not on sale more than seven days ago comes back when a place opens'
UPDATE public.axs_watch_poll SET fired_at = now() - interval '8 days', checked_at = now() - interval '8 days' WHERE axs_event_id = '109';
UPDATE public.axs_watch_venue SET quota = 7;
SELECT (public.axs_watch_fill(true)) - 'run' AS fourth_fill;
SELECT source_event_id AS id, name FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;

\echo '--- F. a shorter recheck time lets the others back sooner; never under a day'
UPDATE public.axs_watch_config SET not_on_sale_recheck = interval '1 day';
UPDATE public.axs_watch_poll SET fired_at = now() - interval '25 hours', checked_at = now() - interval '25 hours' WHERE axs_event_id = '102' AND outcome = 'unparsed';
UPDATE public.axs_watch_venue SET quota = 8;
SELECT (public.axs_watch_fill(true)) -> 'added' AS added;
SELECT source_event_id AS id FROM public.primary_poll_event WHERE source = 'axs' AND source_event_id IN ('102', '105', '106') ORDER BY 1;
DO $$ BEGIN
  UPDATE public.axs_watch_config SET not_on_sale_recheck = interval '2 hours';
  RAISE EXCEPTION 'a recheck time under a day was accepted';
EXCEPTION WHEN check_violation THEN RAISE WARNING 'a recheck time of 2 hours is refused';
END $$;
