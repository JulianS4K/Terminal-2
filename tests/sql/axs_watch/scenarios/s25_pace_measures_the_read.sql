-- The pacer measures the READ, not the queue wait (mig 20261126163000).
--
-- axs_watch_pace sized capacity from settle_p50 = checked_at - fired_at. Once the queue ack
-- began setting fired_at to the pacer's release slot (mig 20261126124500), settle absorbed the
-- time an item spent waiting in its lane, so the brake throttled the operator's bands on a
-- number the queue itself had inflated. response_s is TicketsData's own elapsed_seconds for
-- that read: the cost that is actually ours to pay.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker', read_spacing_ms = 3000;

\echo '--- A. 60 reads that each took 6s upstream but sat 9s in a queue lane before finishing'
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code,
        outcome, response_s, listings, reader)
SELECT 70000+g, 'PACE'||g,
       now() - make_interval(secs => 900 - g*10),          -- the release slot
       now() - make_interval(secs => 900 - g*10) + interval '9 seconds',  -- settled 9s later
       200, 'ok', 6.0, 5, 'worker'
  FROM generate_series(1,60) g;

\echo '--- B. settle says 9s, the read says 6s; s_per_read must follow the READ'
SELECT (public.axs_watch_pace()) - 'demand_per_hour' - 'events' - 'day_of_events' - 'day_of_fits'
       - 'far_out_every' - 'far_out_days' - 'daily_cap' AS pace;

\echo '--- C. said plainly: the measure is the read + 1s, not the settle + 1s'
WITH p AS (SELECT public.axs_watch_pace() AS j)
SELECT (j->>'settle_p50_s')::numeric AS settle_p50,
       (j->>'response_p50_s')::numeric AS response_p50,
       (j->>'s_per_read')::numeric AS s_per_read,
       (j->>'s_per_read')::numeric = (j->>'response_p50_s')::numeric + 1.0 AS follows_the_read,
       (j->>'s_per_read')::numeric < (j->>'settle_p50_s')::numeric AS beats_the_inflated_settle
  FROM p;

\echo '--- D. THE SPACING FLOOR SURVIVES: a 1s read cannot claim to beat the 3s rule'
DELETE FROM public.axs_watch_poll WHERE axs_event_id LIKE 'PACE%';
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code,
        outcome, response_s, listings, reader)
SELECT 71000+g, 'FAST'||g, now() - make_interval(secs => 600 - g*5),
       now() - make_interval(secs => 600 - g*5) + interval '1 second', 200, 'ok', 1.0, 5, 'worker'
  FROM generate_series(1,40) g;
WITH p AS (SELECT public.axs_watch_pace() AS j)
SELECT (j->>'response_p50_s')::numeric AS response_p50, (j->>'spacing_s')::numeric AS spacing_s,
       (j->>'s_per_read')::numeric AS s_per_read,
       (j->>'s_per_read')::numeric = (j->>'spacing_s')::numeric AS floored_at_the_spacing
  FROM p;

\echo '--- E. a read that TIMED OUT upstream still reports its real cost, so slow is still slow'
DELETE FROM public.axs_watch_poll WHERE axs_event_id LIKE 'FAST%';
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code,
        outcome, error, response_s, reader)
SELECT 72000+g, 'SLOW'||g, now() - make_interval(secs => 900 - g*20),
       now() - make_interval(secs => 900 - g*20) + interval '20 seconds', 200, 'unparsed',
       'unavailable', 20.05, 'worker'
  FROM generate_series(1,40) g;
WITH p AS (SELECT public.axs_watch_pace() AS j)
SELECT (j->>'response_p50_s')::numeric AS response_p50, (j->>'s_per_read')::numeric AS s_per_read,
       (j->>'reads_per_hour')::integer AS reads_per_hour,
       (j->>'s_per_read')::numeric > 20 AS a_20s_read_is_not_hidden
  FROM p;

\echo '--- F. a LOST read has no response_s at all, so the chain falls back to settle'
DELETE FROM public.axs_watch_poll WHERE axs_event_id LIKE 'SLOW%';
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code,
        outcome, error, response_s, reader)
SELECT 73000+g, 'LOST'||g, now() - make_interval(secs => 600 - g*5),
       now() - make_interval(secs => 600 - g*5) + interval '12 seconds', NULL, 'lost',
       'no response within stale_after', NULL, 'worker'
  FROM generate_series(1,30) g;
WITH p AS (SELECT public.axs_watch_pace() AS j)
SELECT (j->>'response_p50_s') AS response_p50_is_null,
       (j->>'settle_p50_s')::numeric AS settle_p50,
       (j->>'s_per_read')::numeric AS s_per_read,
       (j->>'s_per_read')::numeric = (j->>'settle_p50_s')::numeric + 1.0 AS fell_back_to_settle
  FROM p;

\echo '--- G. and the brake: with the honest measure the bands are NOT throttled'
DELETE FROM public.axs_watch_poll WHERE axs_event_id LIKE 'LOST%';
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code,
        outcome, response_s, listings, reader)
SELECT 74000+g, 'OK'||g, now() - make_interval(secs => 900 - g*10),
       now() - make_interval(secs => 900 - g*10) + interval '9 seconds', 200, 'ok', 6.0, 5, 'worker'
  FROM generate_series(1,60) g;
SELECT (public.axs_watch_pace()->>'usable_per_hour')::integer AS usable_honest,
       floor(3600.0 / ((SELECT (public.axs_watch_pace()->>'settle_p50_s')::numeric) + 1.0)
             * (SELECT pace_target_pct FROM public.axs_watch_config) / 100.0)::integer AS usable_if_it_still_measured_settle;

\echo '--- H. the guard is in the installed function, both halves of it'
SELECT pg_get_functiondef(p.oid) ~ 'coalesce\(m\.response_p50, m\.settle_p50, 9\.0\) \+ 1\.0' AS measures_the_read,
       pg_get_functiondef(p.oid) ~ 'cfg\.read_spacing_ms / 1000\.0 ELSE 15\.0 END\) AS s_per_read' AS spacing_floor_intact
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='axs_watch_pace';

\echo '--- I. THE DB PATH keeps measuring the settle: there the wait is pg_net''s own queue,'
\echo '---    which is real capacity, and response_s (the browser run) would not show it.'
UPDATE public.axs_watch_config SET reader = 'db';
DELETE FROM public.axs_watch_poll;
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code,
        outcome, response_s, listings, reader)
SELECT 75000+g, 'DB'||g, now() - make_interval(secs => 900 - g*10),
       now() - make_interval(secs => 900 - g*10) + interval '30 seconds', 200, 'ok', 6.0, 5, 'db'
  FROM generate_series(1,40) g;
WITH p AS (SELECT public.axs_watch_pace() AS j)
SELECT j->>'reader' AS reader, (j->>'settle_p50_s')::numeric AS settle_p50,
       (j->>'response_p50_s')::numeric AS response_p50,
       (j->>'s_per_read')::numeric AS s_per_read,
       (j->>'s_per_read')::numeric = (j->>'settle_p50_s')::numeric + 1.0 AS db_still_measures_the_settle
  FROM p;
UPDATE public.axs_watch_config SET reader = 'worker';
