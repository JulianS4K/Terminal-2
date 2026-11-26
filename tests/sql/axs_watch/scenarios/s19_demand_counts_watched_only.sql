-- The demand gauge and the brake must count the events we READ, not the ones we merely
-- publish (mig 20261126062000). 20261126060000 split the list and left both measuring the
-- whole of it, which would have had the pacer halve the real cadence to relieve pressure
-- that does not exist. No earlier scenario asserted a demand figure against a list holding
-- both kinds of row; this one does.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-s19', now(), 1)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-s19', finished_at = now();

-- 10 events we read, 40 we only publish. All on the same far-out band, so the arithmetic
-- is exact: 90 minutes is 0.667 reads an hour each.
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run, watch)
SELECT 'axs', 'W' || g, 'Watched ' || g, (now() + interval '200 days')::date, now() + interval '200 days',
       'Hall', 'https://www.axs.com/events/W' || g, 'ok', now() + interval '1 hour',
       interval '90 minutes', 'run-s19', true
  FROM generate_series(1, 10) g;
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run, watch)
SELECT 'axs', 'C' || g, 'Catalogue ' || g, (now() + interval '200 days')::date, now() + interval '200 days',
       'Hall', 'https://www.axs.com/events/C' || g, 'pending', NULL,
       NULL, 'run-s19', false
  FROM generate_series(1, 40) g;

\echo '--- A. the list is 50 rows; only 10 of them are demand'
SELECT count(*) AS rows_on_the_list,
       count(*) FILTER (WHERE watch) AS watched,
       count(*) FILTER (WHERE NOT watch) AS catalogue_only
  FROM public.primary_poll_event WHERE source = 'axs';

\echo '--- B. the gauge counts the 10, and says so'
SELECT (public.axs_watch_cadence_demand()) - 'usable_per_hour' - 'daily_cap'
         - 'pct_of_throughput' - 'pct_of_daily_cap' - 'fits' AS demand;

\echo '--- C. the arithmetic: 10 events on the 90-minute band, not 50'
SELECT ((public.axs_watch_cadence_demand())->>'events')::int = 10 AS counts_watched_only,
       ((public.axs_watch_cadence_demand())->>'catalogue_only')::int = 40 AS reports_the_catalogue,
       round(((public.axs_watch_cadence_demand())->>'demand_per_hour')::numeric, 1)
         = round(10 * 3600.0 / 5400, 1) AS demand_is_exact;

\echo '--- D. the brake measures the same set, so it cannot act on the catalogue'
SELECT (public.axs_watch_pace_apply())->'band_demand_per_hour' AS brake_sees,
       (public.axs_watch_cadence_demand())->'demand_per_hour' AS gauge_sees;
SELECT ((public.axs_watch_pace_apply())->>'band_demand_per_hour')::numeric
         = ((public.axs_watch_cadence_demand())->>'demand_per_hour')::numeric
         AS brake_and_gauge_agree;

\echo '--- E. publishing 40 more catalogue rows does not move either one'
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run, watch)
SELECT 'axs', 'X' || g, 'More Catalogue ' || g, (now() + interval '200 days')::date, now() + interval '200 days',
       'Hall', 'https://www.axs.com/events/X' || g, 'pending', NULL, NULL, 'run-s19', false
  FROM generate_series(1, 40) g;
SELECT count(*) AS rows_on_the_list FROM public.primary_poll_event WHERE source = 'axs';
SELECT ((public.axs_watch_cadence_demand())->>'events')::int AS still_10_events,
       round(((public.axs_watch_cadence_demand())->>'demand_per_hour')::numeric, 1) AS still_same_demand;

\echo '--- F. promoting one catalogue row DOES move it, by exactly one event'
UPDATE public.primary_poll_event SET watch = true, next_poll_at = now() + interval '1 hour',
       poll_interval = interval '90 minutes', poll_status = 'ok'
 WHERE source = 'axs' AND source_event_id = 'C1';
SELECT ((public.axs_watch_cadence_demand())->>'events')::int AS now_11_events,
       round(((public.axs_watch_cadence_demand())->>'demand_per_hour')::numeric, 1) AS demand_after;
