-- The deep-GA 2-hour band must survive primary_poll_due's ladder clause (mig 20261126141500).
--
-- The clause lets the SHARED ladder (primary_poll_interval: event_date + median_price +
-- listed_quantity) overtake an event's stored band whenever it is faster. Its price band gives
-- -1 step at median >= 150 and its qty band -1 step at >= 2000, and the max_slowdown_steps
-- clamp limits only SLOWING, so a combined -2 floors the interval at 30 minutes however far
-- out the event is. That was silently undoing the operator's GA rule on every read path that
-- gates on primary_poll_due: axs_watch_next and axs_watch_tick both do.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker';

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-ga', now(), 3)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-ga', finished_at = now();

-- Three events 120 days out, all priced and sized so the shared ladder wants 30 minutes:
--   G1  ga_slow, band 2h   — the rule applies; the ladder must NOT overtake it
--   G2  plain,   band 2h   — the same numbers without the flag; the ladder SHOULD overtake it,
--                            which is what proves the fix is narrow and the clause still works
--   G3  ga_slow, band 2h, but its next_poll_at has arrived — the rule slows, it never stops
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_attempt_at, next_poll_at, poll_interval, median_price, listed_quantity,
        ga_slow, watch, last_run)
SELECT 'axs', v.id, v.nm, (now() + interval '120 days')::date, now() + interval '120 days', 'GA Field',
       'https://www.axs.com/events/'||v.id, 'ok', now() - interval '35 minutes', v.next_at,
       interval '2 hours', 300, 5000, v.ga, true, 'run-ga'
  FROM (VALUES ('G1','Deep GA Rave',      true,  now() + interval '85 minutes'),
               ('G2','Reserved Arena Show',false, now() + interval '85 minutes'),
               ('G3','Deep GA Rave Due',  true,  now() - interval '1 minute')) AS v(id, nm, ga, next_at)
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- A. the two cadences disagree: stored band 2h, shared ladder 30 min, for all three'
SELECT source_event_id, poll_interval AS band_we_set, ga_slow,
       public.primary_poll_interval(event_date, median_price, listed_quantity) AS shared_ladder,
       public.primary_poll_interval(event_date, median_price, listed_quantity) < poll_interval AS ladder_is_faster
  FROM public.primary_poll_event WHERE source='axs' ORDER BY 1;

\echo '--- B. THE FIX. G1 is held to its band; G2 is still overtaken; G3 is due on its own schedule.'
SELECT public.primary_poll_due('axs', '["G1","G2","G3"]'::jsonb) AS due_now;

\echo '--- C. said as three answers, so a future change to the list order cannot hide a regression'
SELECT e.source_event_id,
       jsonb_array_length(public.primary_poll_due('axs', jsonb_build_array(e.source_event_id))) = 1 AS due,
       CASE e.source_event_id WHEN 'G1' THEN 'held by the GA rule'
                              WHEN 'G2' THEN 'overtaken by the ladder, as designed'
                              WHEN 'G3' THEN 'its own next_poll_at has arrived' END AS why
  FROM public.primary_poll_event e WHERE e.source='axs' ORDER BY 1;

\echo '--- D. the rule only ever SLOWS: once G1''s next_poll_at arrives it is due like anything else'
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '1 second'
 WHERE source='axs' AND source_event_id='G1';
SELECT jsonb_array_length(public.primary_poll_due('axs', '["G1"]'::jsonb)) AS g1_due_when_its_time_comes;
UPDATE public.primary_poll_event SET next_poll_at = now() + interval '85 minutes'
 WHERE source='axs' AND source_event_id='G1';

\echo '--- E. the queue path was never exposed (axs_queue_fill reads the band directly) and still is not'
UPDATE public.axs_watch_config SET queue_enabled = true, queue_lanes = 6, daily_cap_override = 5000;
SELECT (public.axs_queue_fill())->'enqueued' AS enqueued;
SELECT axs_event_id, every_min FROM public.axs_read_queue WHERE resolved_at IS NULL ORDER BY 1;

\echo '--- F. inert for every other source: ga_slow is written only by the AXS settle'
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('sitickets', 'run-si', now(), 1)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-si';
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_attempt_at, next_poll_at, poll_interval, median_price, listed_quantity, last_run)
VALUES ('sitickets', 'S1', 'Other Source Show', (now() + interval '120 days')::date, now() + interval '120 days',
        'Elsewhere', 'https://example.test/S1', 'ok', now() - interval '35 minutes',
        now() + interval '85 minutes', interval '2 hours', 300, 5000, 'run-si')
ON CONFLICT (source, source_event_id) DO NOTHING;
SELECT ga_slow IS NOT TRUE AS ga_slow_not_set,
       jsonb_array_length(public.primary_poll_due('sitickets','["S1"]'::jsonb)) = 1 AS still_overtaken_as_before
  FROM public.primary_poll_event WHERE source='sitickets' AND source_event_id='S1';

\echo '--- G. and the guard is actually in the function, not just implied by the answers'
SELECT pg_get_functiondef(p.oid) ~ 'NOT coalesce\(t\.ga_slow, false\)' AS guard_present
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='primary_poll_due';
