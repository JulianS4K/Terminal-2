-- The phase instant must clear due_slack (mig 20261126023000). I introduced this defect in
-- 20261125214500: next_poll_at was set to the first phase-congruent instant after now(), but
-- primary_poll_due calls an event due at next_poll_at <= now() + due_slack, so the chosen instant
-- could land INSIDE that window and the event was handed straight back out — over and over until
-- the clock crossed it. On prod that cost 39.6% of reads at ~20 s latency and 76.1% at ~5 s:
-- a faster upstream made it worse, which is why it hid during the AXS outage.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-phase', now(), 2)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-phase', finished_at = now();

-- THE ADVERSARIAL CASE, made deterministic: a band SHORTER than due_slack. Under the old
-- arithmetic the next instant was at most one band away (<= 5 min) and due_slack is 10 min, so the
-- event was ALWAYS instantly due again, for every event id and every phase — no luck involved.
DELETE FROM public.axs_watch_cadence;
INSERT INTO public.axs_watch_cadence (band, max_days, every, sort_order, note)
VALUES ('tiny', 1e9, interval '5 minutes', 1, 'shorter than due_slack on purpose');
UPDATE public.primary_poll_config SET due_slack = interval '10 minutes';

INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
SELECT 'axs', 'P'||g, 'Phase Case '||g, (now() + interval '40 days')::date, now() + interval '40 days',
       'Big Arena', 'https://www.axs.com/events/P'||g, 'pending', now() - interval '1 hour',
       interval '5 minutes', 'run-phase'
  FROM generate_series(1,12) g
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- A. the setup: the band is 5 min, due_slack is 10 min'
SELECT (SELECT every FROM public.axs_watch_cadence WHERE band='tiny') AS band,
       (SELECT due_slack FROM public.primary_poll_config) AS due_slack;

\echo '--- B. settle all twelve, then assert THE INVARIANT: next_poll_at > now() + due_slack, for every one'
DO $$
DECLARE g integer;
BEGIN
  FOR g IN 1..12 LOOP
    PERFORM public.axs_watch_settle_one('P'||g, 200,
      jsonb_build_object('body', jsonb_build_object('status','ok','exit_code',0,
        'event', jsonb_build_object('id','P'||g), 'listings', '[]'::jsonb)));
  END LOOP;
END $$;
SELECT count(*) AS settled,
       count(*) FILTER (WHERE next_poll_at > now() + (SELECT due_slack FROM public.primary_poll_config)) AS clear_of_slack,
       count(*) FILTER (WHERE next_poll_at <= now() + (SELECT due_slack FROM public.primary_poll_config)) AS inside_slack_would_loop,
       -- asserted as invariants, not as second counts: the gap is measured against now(),
       -- which moves between the settle and this SELECT, so printing it would not be stable
       bool_and(next_poll_at > now() + (SELECT due_slack FROM public.primary_poll_config)) AS every_gap_exceeds_slack,
       bool_and(next_poll_at <= now() + (SELECT due_slack FROM public.primary_poll_config) + poll_interval) AS and_none_exceeds_slack_plus_band
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id LIKE 'P%';

\echo '--- C. and the behaviour that matters: primary_poll_due hands NONE of them back out'
SELECT jsonb_array_length(public.primary_poll_due('axs',
         (SELECT jsonb_agg(source_event_id) FROM public.primary_poll_event
           WHERE source='axs' AND source_event_id LIKE 'P%'))) AS due_right_after_settling;

\echo '--- D. axs_watch_next therefore hands out nothing either — this is the loop, closed'
UPDATE public.axs_watch_config SET reader='worker', daily_cap_override=5000;
SELECT public.axs_watch_next(20)->'events' AS handed_out;

\echo '--- E. the phase is still honoured: each next_poll_at is congruent to the event''s own phase'
SELECT count(*) AS events,
       count(*) FILTER (WHERE (extract(epoch FROM next_poll_at)::bigint % extract(epoch FROM poll_interval)::bigint)
                            = ((hashtext(source_event_id)::bigint & 2147483647) % extract(epoch FROM poll_interval)::bigint))
         AS phase_aligned
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id LIKE 'P%';

\echo '--- F. the gap never exceeds due_slack + one band, so freshness is not given away'
SELECT bool_and(next_poll_at <= now()
                + (SELECT due_slack FROM public.primary_poll_config)
                + poll_interval + interval '2 seconds') AS within_slack_plus_one_band
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id LIKE 'P%';

\echo '--- G. with the ordinary 60s slack and a 60-minute band, the same invariant holds'
UPDATE public.primary_poll_config SET due_slack = interval '1 minute';
DELETE FROM public.axs_watch_cadence;
INSERT INTO public.axs_watch_cadence (band, max_days, every, sort_order) VALUES ('hour', 1e9, interval '60 minutes', 1);
DO $$
DECLARE g integer;
BEGIN
  FOR g IN 1..12 LOOP
    PERFORM public.axs_watch_settle_one('P'||g, 200,
      jsonb_build_object('body', jsonb_build_object('status','ok','exit_code',0,
        'event', jsonb_build_object('id','P'||g), 'listings', '[]'::jsonb)));
  END LOOP;
END $$;
SELECT count(*) FILTER (WHERE next_poll_at > now() + interval '1 minute') AS clear_of_slack,
       bool_and(next_poll_at > now() + interval '1 minute') AS every_gap_exceeds_slack,
       bool_and(next_poll_at <= now() + interval '1 minute' + poll_interval) AS and_none_exceeds_slack_plus_band,
       jsonb_array_length(public.primary_poll_due('axs',
         (SELECT jsonb_agg(source_event_id) FROM public.primary_poll_event
           WHERE source='axs' AND source_event_id LIKE 'P%'))) AS due_now
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id LIKE 'P%';
