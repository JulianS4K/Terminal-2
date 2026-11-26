-- The AXS read queue (mig 20261126030000). Operator 2026-11-26: "what if we built a queue system",
-- then "phase fix and test, then queue and test".
-- The point of the whole thing is ONE index: at most one unresolved item per event, enforced by a
-- UNIQUE partial index rather than by a check-then-insert. Tonight's two scheduling bugs — a hold
-- that latched on, and a phase that re-armed inside due_slack and re-read everything a dozen times
-- a cycle — were both arithmetic, not dispatch. The queue does not make the arithmetic right; it
-- makes it cheap.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-queue', now(), 4)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-queue', finished_at = now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
SELECT 'axs', 'Q'||g, 'Queue Case '||g, (now() + interval '40 days')::date, now() + interval '40 days',
       'Big Arena', 'https://www.axs.com/events/Q'||g, 'pending', now() - interval '5 minutes',
       interval '30 minutes', 'run-queue'
  FROM generate_series(1,4) g
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- A. it ships DARK: queue_enabled is false, so claim hands out nothing and the live path is untouched'
SELECT queue_enabled, queue_lanes FROM public.axs_watch_config;
SELECT public.axs_queue_claim('w1') - 'depth' AS claim_while_off;

\echo '--- B. fill enqueues the four due events, once each'
SELECT (public.axs_queue_fill()) - 'depth' AS fill;
SELECT count(*) AS queued, count(DISTINCT axs_event_id) AS distinct_events FROM public.axs_read_queue;

\echo '--- C. THE INVARIANT. Fill ten more times — a scheduler screaming "due!" — and the depth does not move.'
DO $$ BEGIN FOR i IN 1..10 LOOP PERFORM public.axs_queue_fill(); END LOOP; END $$;
SELECT count(*) AS still_queued, count(DISTINCT axs_event_id) AS distinct_events,
       max(attempts) AS max_attempts FROM public.axs_read_queue WHERE resolved_at IS NULL;

\echo '--- D. and the index refuses a duplicate outright, not by a check the caller might skip'
DO $$
BEGIN
  INSERT INTO public.axs_read_queue (axs_event_id, event_url, every_min, due_at)
  VALUES ('Q1', 'https://www.axs.com/events/Q1', 30, now());
  RAISE WARNING 'a second open item for Q1 was ACCEPTED';
EXCEPTION WHEN unique_violation THEN RAISE WARNING 'a second open item for Q1 is refused by the index'; END $$;

\echo '--- E. turn it on: one lane, so exactly one item is handed out and it carries a release_at'
UPDATE public.axs_watch_config SET queue_enabled = true, daily_cap_override = 5000;
WITH c AS (SELECT public.axs_queue_claim('w1') AS j)
SELECT jsonb_array_length(c.j->'items') AS items,
       c.j->'items'->0->>'id' AS event,
       c.j->'items'->0->>'every_min' AS every_min,
       c.j->'items'->0->>'attempts' AS attempts,
       (c.j->'items'->0->>'release_at')::timestamptz >= now() - interval '2 seconds' AS release_at_not_in_the_past,
       c.j->>'lanes' AS lanes, c.j->>'in_flight' AS in_flight, c.j->>'spacing_ms' AS spacing_ms
  FROM c;

\echo '--- F. a second worker gets nothing while the lane is busy — this is the 3-second rule held centrally'
SELECT (public.axs_queue_claim('w2')) - 'depth' - 'daily_cap' - 'fired_today' AS second_worker;

\echo '--- G. three lanes: three items, and their release_at slots are spaced read_spacing_ms apart'
UPDATE public.axs_watch_config SET queue_lanes = 3;
SELECT (public.axs_queue_claim('w2', 3))->'items' IS NOT NULL AS claimed_more;
SELECT count(*) AS in_flight,
       count(DISTINCT release_at) AS distinct_slots,
       (max(release_at) - min(release_at)) >= interval '3 seconds' AS slots_at_least_3s_apart,
       bool_and(release_at >= claimed_at) AS never_released_before_claim
  FROM public.axs_read_queue WHERE resolved_at IS NULL AND claimed_at IS NOT NULL;

\echo '--- H. ack settles the read: the event is ingested, the band is set, the item resolves'
SELECT (public.axs_queue_ack((SELECT min(id) FROM public.axs_read_queue WHERE resolved_at IS NULL AND claimed_at IS NOT NULL),
         200, $j${"status":"ok","quota_remaining":99990,"body":{"status":"ok","exit_code":0,"event":{"id":"Q1"},
         "listings":[{"kind":"primary","section":"101","row":"A","seats":["1","2"],"quantity":2,"status":"Available",
         "pricing":{"face":40,"fees_total":6,"tax":0,"all_in":46}}]}}$j$::jsonb)) - 'request_id' - 'quota_remaining' AS ack;
SELECT axs_event_id, outcome, resolved_at IS NOT NULL AS resolved FROM public.axs_read_queue WHERE resolved_at IS NOT NULL;

\echo '--- I. acking the same item again is harmless and charges nothing twice (a worker retrying a lost answer)'
SELECT (public.axs_queue_ack((SELECT min(id) FROM public.axs_read_queue WHERE resolved_at IS NOT NULL),
         200, $j${"body":{"status":"ok","exit_code":0,"event":{"id":"Q1"},"listings":[]}}$j$::jsonb)) AS second_ack;

\echo '--- J. a worker that dies: its lease expires and the item goes back to pending, attempts +1'
UPDATE public.axs_read_queue SET lease_until = now() - interval '1 second'
 WHERE resolved_at IS NULL AND claimed_at IS NOT NULL;
SELECT public.axs_queue_reap() AS reaped;
SELECT count(*) FILTER (WHERE claimed_at IS NULL) AS back_to_pending,
       max(attempts) AS attempts FROM public.axs_read_queue WHERE resolved_at IS NULL;

\echo '--- K. the hold still applies: three fresh upstream errors and the queue hands out nothing'
-- These must be the NEWEST reads in the ledger. The hold needs three of the last ten to
-- have failed upstream AND the newest of them to have failed, so a later success releases
-- it by design. Until mig 20261126124500 the ack in section H wrote no axs_watch_poll row
-- and this fixture could backdate its failures 26-28 seconds behind it; now the ack writes
-- a real 'ok' row at its own now(), which would be newer than a backdated 502 and would
-- (correctly) release the hold. So the failures are stamped at this statement's now(),
-- which is after the ack's.
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, error)
SELECT 8000+g, 'Q1', now() - make_interval(secs => 4-g), now() - make_interval(secs => 3-g),
       502, 'upstream_error', 'HTTP 502 from TicketsData' FROM generate_series(1,3) g;
SELECT (public.axs_queue_claim('w1')) - 'depth' AS held_by_upstream;

\echo '--- L. depth is the one number that says whether we are keeping up'
SELECT (public.axs_queue_depth()) - 'oldest_pending_age_s' AS depth_without_the_moving_age,
       (public.axs_queue_depth()->>'oldest_pending_age_s')::numeric < 120 AS oldest_pending_is_recent;

\echo '--- M. the bands are honoured, NOT primary_poll_due''s ladder bypass: an event parked an hour out is not enqueued'
DELETE FROM public.axs_watch_poll WHERE axs_event_id='Q1' AND status_code=502;
UPDATE public.primary_poll_event SET next_poll_at = now() + interval '29 minutes', poll_interval = interval '1 hour',
       median_price = 215, listed_quantity = 1800, poll_attempt_at = now() - interval '31 minutes'
 WHERE source='axs' AND source_event_id='Q4';
DELETE FROM public.axs_read_queue WHERE axs_event_id='Q4';
SELECT public.primary_poll_interval((SELECT event_date FROM public.primary_poll_event WHERE source='axs' AND source_event_id='Q4'),
         215, 1800) AS shared_ladder_says,
       (SELECT poll_interval FROM public.primary_poll_event WHERE source='axs' AND source_event_id='Q4') AS band_says,
       jsonb_array_length(public.primary_poll_due('axs', '["Q4"]'::jsonb)) AS primary_poll_due_would_say_due;
SELECT (public.axs_queue_fill())->'enqueued' AS queue_enqueued_it,
       (SELECT count(*) FROM public.axs_read_queue WHERE axs_event_id='Q4' AND resolved_at IS NULL) AS q4_open_items;
