-- The hourly pacer sets cadence_scale, the knob axs_watch_cadence_every() actually reads
-- (mig 20261126053000). Before it, pace_apply only moved far_out_every, which stopped
-- governing the cadence at 20261126011500 — so the watch had no working brake.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the clamps, as seeded'
SELECT cadence_scale, cadence_scale_floor, cadence_scale_max FROM public.axs_watch_config;

-- A reader fast enough to measure from: 40 reads at ~4s, so usable_per_hour is healthy.
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-pace2', now(), 1)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-pace2', finished_at = now();
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, outcome, response_s, reader)
SELECT 900000 + g, 'P' || g, now() - make_interval(secs => g * 9), now() - make_interval(secs => g * 9 - 4),
       'ok', 4.0, 'worker'
  FROM generate_series(1, 40) g;
SELECT count(*) AS synthetic_reads_measured, round(avg(response_s),1) AS avg_response_s
  FROM public.axs_watch_poll WHERE axs_event_id LIKE 'P%';

\echo '--- B. a small list: demand is under throughput, so the floor holds the scale at 1.0'
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
SELECT 'axs', 'S' || g, 'Far Out ' || g, (now() + interval '200 days')::date, now() + interval '200 days',
       'Small Hall', 'https://www.axs.com/events/S' || g, 'ok', now(), interval '90 minutes', 'run-pace2'
  FROM generate_series(1, 5) g
ON CONFLICT (source, source_event_id) DO NOTHING;
SELECT (public.axs_watch_pace_apply()) -> 'cadence_scale' AS scale_small_list,
       (public.axs_watch_pace_apply()) -> 'cadence_scale_changed' AS changed;
SELECT cadence_scale FROM public.axs_watch_config;

\echo '--- C. a list that outruns the reader: the scale rises, and the bands widen with it'
-- 900 far-out events at 90 minutes = 600 reads/hour against ~675 usable... so make it hurt:
-- day-of events on the 30-minute band, which is the expensive rung.
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
SELECT 'axs', 'H' || g, 'Soon ' || g, (now() + interval '2 days')::date, now() + interval '2 days',
       'Big Arena', 'https://www.axs.com/events/H' || g, 'ok', now(), interval '30 minutes', 'run-pace2'
  FROM generate_series(1, 900) g
ON CONFLICT (source, source_event_id) DO NOTHING;
SELECT count(*) AS events_on_the_watch FROM public.primary_poll_event WHERE source = 'axs';
SELECT (public.axs_watch_cadence_demand()) -> 'fits' AS fits_before_pacing;
SELECT (public.axs_watch_pace_apply()) -> 'cadence_scale_changed' AS scale_moved;
SELECT cadence_scale > 1.0 AS scale_rose,
       cadence_scale <= cadence_scale_max AS within_clamp FROM public.axs_watch_config;

\echo '--- D. the bands widen by exactly the scale'
SELECT public.axs_watch_cadence_every(now() + interval '2 days', NULL)
         = interval '30 minutes' * (SELECT cadence_scale FROM public.axs_watch_config) AS band_follows_scale;

\echo '--- E. at the clamp it says so rather than pretending it fitted'
UPDATE public.axs_watch_config SET cadence_scale = 1.0, cadence_scale_max = 1.5;
SELECT (public.axs_watch_pace_apply()) ->> 'cadence_scale' AS scale_at_clamp;
SELECT pace_note ~ 'clamped at cadence_scale_max' AS note_admits_the_clamp,
       cadence_scale = cadence_scale_max AS pinned_at_max FROM public.axs_watch_config;
SELECT (public.axs_watch_cadence_demand()) -> 'fits' AS fits_at_the_clamp;  -- false: pinned at 1.5, the list still outruns the reader

\echo '--- F. hysteresis: a second run at the same measurement changes nothing'
UPDATE public.axs_watch_config SET cadence_scale_max = 8.0;  -- the most cadence_scale's own CHECK allows
SELECT (public.axs_watch_pace_apply()) -> 'cadence_scale_changed' AS first_run_moves_it;
SELECT (public.axs_watch_pace_apply()) -> 'cadence_scale_changed' AS second_run_holds;

\echo '--- G. cadence_scale_max cannot be set outside cadence_scale''s own domain'
-- a max above 8.0 would let the pacer compute a scale the column rejects, and the hourly
-- job would throw at :07 instead of braking
SELECT (SELECT pg_get_constraintdef(oid) FROM pg_constraint
         WHERE conrelid = 'public.axs_watch_config'::regclass
           AND conname = 'axs_watch_config_cadence_scale_check') AS cadence_scale_domain;
SELECT (SELECT count(*) FROM pg_constraint
         WHERE conrelid = 'public.axs_watch_config'::regclass
           AND pg_get_constraintdef(oid) ~ 'cadence_scale_max.*8\.0') = 1 AS max_bounded_at_8;
SELECT public.axs_watch_cadence_every(now() + interval '2 days', NULL) <= interval '30 minutes' * 8.0
         AS widest_possible_band_is_bounded;

\echo '--- H. far_out_every is still maintained for whatever still reads it'
SELECT far_out_every IS NOT NULL AS legacy_knob_still_set FROM public.axs_watch_config;
