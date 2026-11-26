-- The upstream-trouble hold must be able to clear itself (mig 20261126004500). Before the window, the sample was
-- the last ten reads whenever they were made, so once the breaker tripped the only thing that could change its
-- verdict was a new read — and the breaker was what stopped any read being handed out. On prod that left the AXS
-- watch dark for 64 minutes after TicketsData returned eight HTTP 502s, with the worker still renewing its lease.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL;  -- these fixtures are not the operator's three teams

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-hold', now(), 2)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-hold', finished_at = now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
VALUES ('axs','H1','Next Week',  (now() + interval '9 days')::date,  now() + interval '9 days',  'Big Arena',
        'https://www.axs.com/events/H1', 'pending', now() - interval '1 hour', interval '15 minutes', 'run-hold'),
       ('axs','H2','Next Month', (now() + interval '40 days')::date, now() + interval '40 days', 'Big Arena',
        'https://www.axs.com/events/H2', 'pending', now() - interval '1 hour', interval '30 minutes', 'run-hold')
ON CONFLICT (source, source_event_id) DO NOTHING;
UPDATE public.axs_watch_config SET reader = 'worker', upstream_errors_max = 3, daily_cap_override = 500;

\echo '--- A. the window, and a quiet upstream: both events are handed out'
SELECT upstream_errors_max, upstream_errors_window FROM public.axs_watch_config;
SELECT (public.axs_watch_next(20))->'events' AS handed_out, (public.axs_watch_next(20))->'upstream_errors' AS errors;

\echo '--- B. eight HTTP 502s in a row INSIDE the window: the breaker trips and nothing is handed out'
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, error)
SELECT 7000 + g, CASE WHEN g % 2 = 0 THEN 'H1' ELSE 'H2' END,
       now() - make_interval(secs => 120 - g), now() - make_interval(secs => 119 - g),
       502, 'upstream_error', 'HTTP 502 from TicketsData'
  FROM generate_series(1, 8) g;
SELECT (public.axs_watch_next(20)) - 'daily_cap' - 'fired_today' AS held;

\echo '--- C. the hold does NOT depend on a new read to clear: age those failures past the window and it lifts'
-- exactly what the prod incident could not do. No read is added here; only time passes.
UPDATE public.axs_watch_poll SET fired_at = fired_at - interval '30 minutes', checked_at = checked_at - interval '30 minutes'
 WHERE request_id BETWEEN 7001 AND 7008;
SELECT (public.axs_watch_next(20))->'events' AS handed_out_again,
       (public.axs_watch_next(20))->'upstream_errors' AS errors_now;

\echo '--- D. a still-broken upstream re-trips it: three fresh failures are enough'
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, error)
SELECT 7100 + g, 'H1', now() - make_interval(secs => 30 - g), now() - make_interval(secs => 29 - g),
       502, 'upstream_error', 'HTTP 502 from TicketsData'
  FROM generate_series(1, 3) g;
SELECT (public.axs_watch_next(20)) - 'daily_cap' - 'fired_today' AS held_again;

\echo '--- E. a recovered upstream clears it at once: the newest read inside the window is not a failure'
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, listings)
VALUES (7200, 'H1', now() - interval '5 seconds', now() - interval '4 seconds', 200, 'ok', 12);
SELECT (public.axs_watch_next(20))->'events' AS handed_out_after_recovery,
       (public.axs_watch_next(20))->'upstream_errors' AS errors_still_counted;

\echo '--- F. the window is bounded: it cannot be set to nothing, nor to a whole day'
SELECT public.axs_watch_next(0)->'events' AS zero_limit;
CREATE TEMP TABLE _bounds (tried interval, outcome text);
DO $$
DECLARE v interval;
BEGIN
  FOREACH v IN ARRAY ARRAY[interval '10 seconds', interval '6 hours', interval '2 minutes'] LOOP
    BEGIN
      UPDATE public.axs_watch_config SET upstream_errors_window = v;
      INSERT INTO _bounds VALUES (v, 'accepted');
    EXCEPTION WHEN check_violation THEN
      INSERT INTO _bounds VALUES (v, 'refused');
    END;
  END LOOP;
END $$;
SELECT tried, outcome FROM _bounds ORDER BY tried;
SELECT upstream_errors_window AS left_at FROM public.axs_watch_config;
