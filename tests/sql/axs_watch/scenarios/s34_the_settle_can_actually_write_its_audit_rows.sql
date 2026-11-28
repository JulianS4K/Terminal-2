-- The regression test for the outage of 2026-11-28 00:00-00:28Z.
--
-- Migrations 20261127230000 and 20261127240000 each added an audit INSERT inside
-- axs_watch_settle_one. Both were wrong against the real table: the first omitted run_id,
-- which is NOT NULL, and the second used action 'non_transferable', which the
-- axs_watch_audit_action_check CHECK rejected. Every read whose body tripped a detector
-- therefore raised inside the settle, axs_queue_ack answered HTTP 400, the read was never
-- acked, its lane orphaned, and the reaper requeued it forever. AXS reads stopped for 29
-- minutes.
--
-- s32 and s33 both "covered" these code paths and both passed, because they asserted on the
-- TEXT of the function -- position('axs_watch_non_transferable' in src) > 0 -- and never once
-- ran a settle over a body that trips the detector. A string match is not a test. This
-- scenario calls the settle for real, which is the only thing that would have caught it.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker', queue_enabled = true;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-audit', now(), 2)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-audit', finished_at = now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc,
        venue_name, ticket_url, poll_status, next_poll_at, poll_interval, last_run, watch)
VALUES ('axs','NT1','Non-Transferable Show',(now()+interval '30 days')::date, now()+interval '30 days',
        'Ryman Auditorium','https://www.axs.com/events/NT1','pending', now()-interval '5 min',
        interval '60 minutes','run-audit', true),
       ('axs','WP1','Wrong Performance Show',(now()+interval '30 days')::date, now()+interval '30 days',
        'Toyota Center','https://www.axs.com/events/WP1','pending', now()-interval '5 min',
        interval '60 minutes','run-audit', true)
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- A. a non-transferable body settles without raising, and files its audit row'
SELECT (public.axs_watch_settle_one('NT1', 200, jsonb_build_object('body', jsonb_build_object(
          'status','ok','exit_code',0,
          'event', jsonb_build_object('id','NT1','starts_local','2026-12-22T19:30:00-06:00',
                   'description','TICKETS FOR THIS EVENT ARE NON-TRANSFERABLE UNDER ANY CIRCUMSTANCE.',
                   'venue', jsonb_build_object('name','Ryman Auditorium')),
          'delivery_methods', jsonb_build_array(
             jsonb_build_object('label','AXS Mobile ID - Free (Non-Transferable)')),
          'listings', '[]'::jsonb)), false, NULL, false, 'test'))->>'outcome' AS outcome;
SELECT action, axs_event_id, (run_id IS NOT NULL) AS has_run_id
  FROM public.axs_watch_audit WHERE axs_event_id = 'NT1' ORDER BY action;

\echo '--- B. and the event is retired: marked, unwatched, not published'
SELECT non_transferable, watch, listing_count FROM public.primary_poll_event
 WHERE source='axs' AND source_event_id='NT1';
SELECT count(*) AS in_events_feed FROM public.v_primary_poll_events_feed
 WHERE source='axs' AND event_id='NT1';

\echo '--- C. a wrong-performance body settles without raising, and files its audit row'
SELECT (public.axs_watch_settle_one('WP1', 200, jsonb_build_object('body', jsonb_build_object(
          'status','ok','exit_code',0,
          'event', jsonb_build_object('id','WP1','starts_local','2026-12-11T19:30:00-06:00',
                   'venue', jsonb_build_object('name','Toyota Center')),
          'onsale', jsonb_build_object('sub_events', jsonb_build_array(jsonb_build_object(
                    'date','2026-12-11 15:00:00','title','TSO - 3:00 PM'))),
          'listings', '[]'::jsonb)), false, NULL, false, 'test'))->>'outcome' AS outcome;
SELECT action, axs_event_id, (run_id IS NOT NULL) AS has_run_id
  FROM public.axs_watch_audit WHERE axs_event_id = 'WP1' ORDER BY action;

\echo '--- D. observe mode: the wrong-performance read still published its listings'
SELECT withhold_wrong_performance FROM public.axs_watch_config;
SELECT poll_status FROM public.primary_poll_event WHERE source='axs' AND source_event_id='WP1';

\echo '--- E. every audit action the settle can write is permitted by the CHECK'
SELECT pg_get_constraintdef(oid) LIKE '%wrong_performance%'
   AND pg_get_constraintdef(oid) LIKE '%non_transferable%' AS check_admits_both
  FROM pg_constraint
 WHERE conrelid='public.axs_watch_audit'::regclass AND conname='axs_watch_audit_action_check';
