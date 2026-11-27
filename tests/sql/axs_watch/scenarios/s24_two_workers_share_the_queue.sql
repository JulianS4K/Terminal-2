-- CAN A SECOND WORKER SHARE THE LOAD? Operator 2026-11-26: "what if we built a second worker
-- to share the load? Test first against resources available".
--
-- This is the test of the proposition, not of a change: nothing in the schema is altered to
-- support two workers, because the queue was built for it (mig 20261126030000). What has to
-- hold for a second reader to be safe:
--   1. two workers never get the same item        (FOR UPDATE SKIP LOCKED + the unique index)
--   2. no event is read twice concurrently        (the unique partial index on open items)
--   3. TicketsData's spacing is honoured ACROSS both, not per worker — the release slots come
--      from one serialised place (axs_watch_config FOR UPDATE + last_release_at), which is the
--      whole reason the pacer lives in the database and not in the worker
--   4. the daily credit cap still binds across both, so a second worker cannot overspend
--   5. a worker that dies does not strand its items (the lease + axs_queue_reap)
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker',
       queue_enabled = true, queue_lanes = 3, read_spacing_ms = 3000, daily_cap_override = 5000;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-2w', now(), 8)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-2w', finished_at = now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, watch, last_run)
SELECT 'axs', 'W'||g, 'Shared Load '||g, (now() + interval '50 days')::date, now() + interval '50 days',
       'Two Worker Arena', 'https://www.axs.com/events/W'||g, 'pending', now() - interval '5 minutes',
       interval '30 minutes', true, 'run-2w'
  FROM generate_series(1,8) g
ON CONFLICT (source, source_event_id) DO NOTHING;
SELECT (public.axs_queue_fill())->'enqueued' AS enqueued;

\echo '--- A. worker ONE claims its lanes'
WITH c AS (SELECT public.axs_queue_claim('alpha') AS j)
SELECT jsonb_array_length(c.j->'items') AS alpha_items, c.j->>'lanes' AS lanes,
       c.j->>'in_flight' AS in_flight FROM c;

\echo '--- B. THE FINDING. queue_lanes is a GLOBAL in-flight ceiling, not a per-worker one:'
\echo '---    v_room = least(p_limit, queue_lanes) - in_flight. alpha passed no limit (which is'
\echo '---    what core/axs_watch_reader.run_queue does, batch=None), so it took all 3 lanes and'
\echo '---    beta STARVES. A second worker needs queue_lanes raised to have room to work in.'
WITH c AS (SELECT public.axs_queue_claim('beta') AS j)
SELECT jsonb_array_length(c.j->'items') AS beta_items, c.j->>'reason' AS reason,
       c.j->>'hold_s' AS hold_s, c.j->>'in_flight' AS in_flight FROM c;

\echo '--- B2. raise the lanes and beta gets work at once, on DIFFERENT events (rule 1)'
UPDATE public.axs_watch_config SET queue_lanes = 6;
WITH c AS (SELECT public.axs_queue_claim('beta') AS j)
SELECT jsonb_array_length(c.j->'items') AS beta_items, c.j->>'in_flight' AS in_flight FROM c;
SELECT count(*) AS claimed_total, count(DISTINCT axs_event_id) AS distinct_events,
       count(DISTINCT claimed_by) AS workers,
       count(*) = count(DISTINCT axs_event_id) AS no_event_claimed_twice
  FROM public.axs_read_queue WHERE resolved_at IS NULL AND claimed_at IS NOT NULL;

\echo '--- C. who holds what: disjoint sets, which is the whole point'
SELECT claimed_by, string_agg(axs_event_id, ',' ORDER BY axs_event_id) AS events
  FROM public.axs_read_queue WHERE resolved_at IS NULL AND claimed_at IS NOT NULL
 GROUP BY 1 ORDER BY 1;

\echo '--- D. RULE 3, the one that matters for compliance: spacing holds ACROSS both workers.'
\echo '---    Every gap between consecutive release slots, over the two workers together.'
WITH slots AS (
  SELECT release_at, row_number() OVER (ORDER BY release_at) rn
    FROM public.axs_read_queue WHERE resolved_at IS NULL AND claimed_at IS NOT NULL),
gaps AS (SELECT (b.release_at - a.release_at) AS gap FROM slots a JOIN slots b ON b.rn = a.rn + 1)
SELECT count(*) AS gaps_measured,
       min(gap) AS smallest_gap,
       bool_and(gap >= interval '3 seconds') AS every_gap_at_least_3s
  FROM gaps;

\echo '--- E. and no two slots are identical, across workers'
SELECT count(*) AS slots, count(DISTINCT release_at) AS distinct_slots,
       count(*) = count(DISTINCT release_at) AS all_slots_unique
  FROM public.axs_read_queue WHERE resolved_at IS NULL AND claimed_at IS NOT NULL;

\echo '--- F. RULE 2: the index refuses a second OPEN item for an event, whoever asks'
DO $$
DECLARE v_id text;
BEGIN
  SELECT axs_event_id INTO v_id FROM public.axs_read_queue WHERE resolved_at IS NULL LIMIT 1;
  INSERT INTO public.axs_read_queue (axs_event_id, event_url, every_min, due_at)
  VALUES (v_id, 'https://www.axs.com/events/'||v_id, 30, now());
  RAISE WARNING 'a second open item was ACCEPTED for %', v_id;
EXCEPTION WHEN unique_violation THEN RAISE WARNING 'a second open item is refused by the index'; END $$;

\echo '--- G. both workers ack their own items and each read lands once in the ledger'
DO $$
DECLARE q record; n integer := 0;
BEGIN
  FOR q IN SELECT id, axs_event_id FROM public.axs_read_queue
            WHERE resolved_at IS NULL AND claimed_at IS NOT NULL ORDER BY id
  LOOP
    PERFORM public.axs_queue_ack(q.id, 200, jsonb_build_object('status','ok','quota_remaining',99000,
      'body', jsonb_build_object('status','ok','exit_code',0,'event',jsonb_build_object('id',q.axs_event_id),
        'listings', jsonb_build_array(jsonb_build_object('kind','primary','section','1','row','A',
          -- 40 tickets, not 1: under thin_min_tickets (20) mig 20261126230000 parks every one of
          -- these on the 24-hour band, and mig 20261127000000 then lets a parked read past the
          -- daily cap — which would stop section F testing the cap at all (s31 owns that)
          'quantity',40,'status','Available',
          'pricing', jsonb_build_object('face',10,'fees_total',0,'tax',0,'all_in',10))))));
    n := n + 1;
  END LOOP;
  RAISE WARNING 'acked % items', n;
END $$;
SELECT count(*) AS ledger_rows, count(DISTINCT axs_event_id) AS distinct_events,
       count(*) = count(DISTINCT axs_event_id) AS each_event_once,
       count(DISTINCT reader) AS readers
  FROM public.axs_watch_poll;

\echo '--- H. RULE 4: the cap binds across BOTH workers, not per worker'
UPDATE public.axs_watch_config SET daily_cap_override = 1;
SELECT (public.axs_queue_claim('alpha')) - 'depth' AS alpha_over_cap;
SELECT (public.axs_queue_claim('beta'))  - 'depth' AS beta_over_cap;
UPDATE public.axs_watch_config SET daily_cap_override = 5000;

\echo '--- I. RULE 5: beta dies holding items; the lease expires and they return to the pool'
SELECT (public.axs_queue_claim('beta'))->'items'->0->>'id' AS beta_took;
UPDATE public.axs_read_queue SET lease_until = now() - interval '1 second'
 WHERE resolved_at IS NULL AND claimed_by = 'beta';
SELECT public.axs_queue_reap() AS reaped;
SELECT count(*) FILTER (WHERE claimed_at IS NULL) AS back_in_the_pool,
       max(attempts) AS attempts
  FROM public.axs_read_queue WHERE resolved_at IS NULL;

\echo '--- J. alpha picks up what beta dropped — the load really is shared'
SELECT (public.axs_queue_claim('alpha'))->'items'->0->>'id' AS alpha_picked_it_up;
