-- The cadence follows the reader (mig 20261125010000): the measured seconds a read takes set how many reads an hour the
-- watch may ask for, and the slowest rung (far_out_every) is the fastest one whose demand fits that and the day's credit
-- cap. An event TicketsData reports as not on sale is read every not_on_sale_every instead of the ladder's rung.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL;  -- these fixtures are not the operator's three teams (mig 20261125232000)

-- seven watched events on the ladder: one today (10 min), two within two days (30 min), one in a week (an hour), three far out
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, venue_name, ticket_url, poll_status, next_poll_at, poll_interval)
VALUES ('axs', '41', 'Tonight',     current_date,      'Big Arena', 'https://www.axs.com/events/41', 'ok', now() + interval '1 day', interval '10 minutes'),
       ('axs', '42', 'Tomorrow',    current_date + 1,  'Big Arena', 'https://www.axs.com/events/42', 'ok', now() + interval '1 day', interval '30 minutes'),
       ('axs', '43', 'Day after',   current_date + 2,  'Big Arena', 'https://www.axs.com/events/43', 'ok', now() + interval '1 day', interval '30 minutes'),
       ('axs', '44', 'Next week',   current_date + 7,  'Big Arena', 'https://www.axs.com/events/44', 'ok', now() + interval '1 day', interval '1 hour'),
       ('axs', '45', 'Next month',  current_date + 30, 'Big Arena', 'https://www.axs.com/events/45', 'ok', now() + interval '1 day', interval '1 hour'),
       ('axs', '46', 'In spring',   current_date + 90, 'Big Arena', 'https://www.axs.com/events/46', 'ok', now() + interval '1 day', interval '1 hour'),
       ('axs', '47', 'Coming soon', current_date + 60, 'Big Arena', 'https://www.axs.com/events/47', 'pending', now() - interval '1 hour', interval '1 hour');
INSERT INTO public.ticketsdata_credit_usage (credits, platform, endpoint, status_code, quota_remaining) VALUES (1, 'AXS', '/events?mode=all', 200, 100000);
UPDATE public.axs_watch_config SET reader = 'worker', read_spacing_ms = 3000, far_out_days = 14, far_out_every = interval '2 hours', daily_cap_override = 5000;

\echo '--- A. the measurement: twenty worker reads settling in 7.6 s (TicketsData 6.4 s of it); a read takes 8.6 s, the ladder''s demand at each rung'
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, response_s, listings, reader)
SELECT 2000000000000 + g, '45', now() - (g * interval '20 seconds'), now() - (g * interval '20 seconds') + interval '7.6 seconds', 200, 'ok', 6.4, 100, 'worker'
  FROM generate_series(1, 20) g;
SELECT (public.axs_watch_pace()) - 'daily_cap' AS pace;

\echo '--- B. applied: at 75% of 418 reads an hour the plain ladder (an hour far out) fits; nothing changes but the record'
SELECT (public.axs_watch_pace_apply()) - 'demand_per_hour' - 'daily_cap' - 'reads_measured' - 'settle_p50_s' - 'settle_p90_s' - 'response_p50_s' - 'spacing_s' - 'events' - 'day_of_events' - 'far_out_days' AS applied;
SELECT far_out_every, pace_s_per_read, pace_set_at IS NOT NULL AS pace_set, pace_note FROM public.axs_watch_config;

\echo '--- C. a slow reader (40 s a read) at a 10% target: no rung fits, the slowest allowed is taken; at 100% the hour fits again; the day''s cap also binds'
UPDATE public.axs_watch_poll SET checked_at = fired_at + interval '40 seconds' WHERE reader = 'worker';
UPDATE public.axs_watch_config SET pace_target_pct = 10;
SELECT (public.axs_watch_pace_apply()) - 'note' - 'demand_per_hour' - 'daily_cap' - 'reads_measured' - 'settle_p50_s' - 'settle_p90_s' - 'response_p50_s' - 'spacing_s' - 'events' - 'day_of_events' - 'far_out_days' AS slow_reader;
UPDATE public.axs_watch_config SET pace_target_pct = 100;
SELECT (public.axs_watch_pace_apply())->>'picked' AS fast_again, (public.axs_watch_pace_apply())->>'day_of_fits' AS day_of_fits;
UPDATE public.axs_watch_config SET daily_cap_override = 200;
SELECT (public.axs_watch_pace_apply())->>'picked' AS capped, (public.axs_watch_pace_apply())->>'picked_demand_per_hour' AS demand;
UPDATE public.axs_watch_config SET daily_cap_override = 5000, pace_max_every = interval '3 hours';
SELECT (public.axs_watch_pace_apply())->>'picked' AS within_max;
UPDATE public.axs_watch_config SET pace_max_every = interval '6 hours', pace_target_pct = 75;

\echo '--- D. not on sale: the read is a failed poll, read again in about 6 hours instead of the ladder''s rung; a read that finds tickets puts it back'
SELECT public.axs_watch_record('47', 200, $j${"status": "ok", "quota_remaining": 99999, "body": {"status": "error", "message": "Tickets for this event are not currently on sale."}}$j$::jsonb) - 'request_id' AS not_on_sale;
SELECT source_event_id AS id, poll_status, poll_error, poll_interval, next_poll_at BETWEEN now() + interval '4.5 hours' AND now() + interval '7.5 hours' AS next_in_about_6h
  FROM public.primary_poll_event WHERE source = 'axs' AND source_event_id = '47';
SELECT public.axs_watch_record('47', 200, $j${"status": "ok", "quota_remaining": 99998, "body": {"status": "ok", "exit_code": 0, "event": {"id": "47"}, "listings": [{"kind": "primary", "section": "101", "row": "A", "seats": ["1"], "quantity": 1, "seat_type": "STANDARD", "status": "Available", "pricing": {"face": 50, "all_in": 58}}]}}$j$::jsonb) - 'request_id' AS on_sale_now;
SELECT source_event_id AS id, poll_status, listing_count, poll_interval FROM public.primary_poll_event WHERE source = 'axs' AND source_event_id = '47';

\echo '--- E. the cron and the privileges'
SELECT jobname, schedule FROM cron.job WHERE jobname LIKE 'axs_watch%' ORDER BY jobname;
SELECT p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can, has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_can
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('axs_watch_pace', 'axs_watch_pace_apply') ORDER BY 1;
