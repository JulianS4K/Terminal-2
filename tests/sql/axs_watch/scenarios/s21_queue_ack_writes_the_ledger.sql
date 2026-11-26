-- The queue's ack writes a read row (mig 20261126124500). axs_watch_poll is the read
-- ledger and SIX functions read it; axs_queue_ack previously wrote nothing, so a queue
-- read left no trace. The two that matter most are axs_watch_budget (fired_today, which
-- gates the daily credit cap) and axs_watch_pace (which measures throughput), so this
-- scenario asserts the READERS see queue reads — not merely that a row appears.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker',
       queue_enabled = true, queue_lanes = 6;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-ack', now(), 4)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-ack', finished_at = now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
SELECT 'axs', 'A'||g, 'Ack Case '||g, (now() + interval '40 days')::date, now() + interval '40 days',
       'Big Arena', 'https://www.axs.com/events/A'||g, 'pending', now() - interval '5 minutes',
       interval '30 minutes', 'run-ack'
  FROM generate_series(1,4) g
ON CONFLICT (source, source_event_id) DO NOTHING;
-- A5 is NOT due, so the fill never enqueues it and section H can attribute its row to
-- the due-list path alone.
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
VALUES ('axs','A5','Ack Case 5',(now() + interval '40 days')::date, now() + interval '40 days',
        'Big Arena','https://www.axs.com/events/A5','ok', now() + interval '2 hours',
        interval '30 minutes','run-ack')
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- A. the ledger starts empty, and so does the budget''s day'
SELECT count(*) AS poll_rows FROM public.axs_watch_poll;
SELECT (public.axs_watch_budget())->'fired_today' AS fired_today,
       (public.axs_watch_budget())->'in_flight' AS in_flight;
SELECT (public.axs_watch_pace())->'reads_measured' AS reads_measured;

\echo '--- B. a read goes all the way through the queue: fill, claim, ack'
SELECT (public.axs_queue_fill()) - 'depth' AS fill;
SELECT jsonb_array_length((public.axs_queue_claim('w-ack'))->'items') AS claimed;
SELECT (public.axs_queue_ack(q.id, 200, jsonb_build_object(
          'status','ok','response_s',4.5,'quota_remaining',99000,
          'body', jsonb_build_object('status','ok','exit_code',0,'elapsed_seconds',4.5,
            'event', jsonb_build_object('id', q.axs_event_id),
            'listings', jsonb_build_array(jsonb_build_object(
              'kind','primary','section','101','row','A','seats',jsonb_build_array('1','2'),
              'quantity',2,'status','Available',
              'pricing', jsonb_build_object('face',40,'fees_total',6,'tax',0,'all_in',46))))))
        - 'error') AS ack
  FROM public.axs_read_queue q WHERE q.resolved_at IS NULL ORDER BY q.id LIMIT 1;

\echo '--- C. the ack wrote a ledger row, and it carries the CONFIGURED reader, not "queue"'
-- axs_watch_pace filters WHERE p.reader = cfg.reader, so a row written as "queue" would
-- sit in the ledger while pace still measured nothing: fixed-looking and not fixed.
SELECT p.axs_event_id, p.reader,
       p.reader = (SELECT reader FROM public.axs_watch_config) AS reader_matches_config,
       p.status_code, p.outcome, p.response_s, p.listings, p.quota_remaining,
       p.checked_at IS NOT NULL AS settled,
       p.fired_at <= p.checked_at AS fired_before_checked,
       p.request_id IS NOT NULL AS has_request_id
  FROM public.axs_watch_poll p ORDER BY p.request_id;

\echo '--- D. axs_watch_budget now counts it — this is the daily credit cap working'
SELECT (public.axs_watch_budget())->'fired_today' AS fired_today_after;

\echo '--- E. axs_watch_pace now measures it — this is the brake getting its denominator'
SELECT ((public.axs_watch_pace())->>'reads_measured')::int >= 1 AS pace_sees_the_read,
       ((public.axs_watch_pace())->>'usable_per_hour')::numeric > 0 AS usable_is_real;

\echo '--- F. acking the same item twice writes ONE row (the FOR UPDATE + resolved_at guard)'
SELECT (public.axs_queue_ack(q.id, 200, jsonb_build_object('status','ok',
          'body', jsonb_build_object('status','ok','exit_code',0,
            'event', jsonb_build_object('id', q.axs_event_id), 'listings', '[]'::jsonb))))
        ->'already_resolved' AS second_ack
  FROM public.axs_read_queue q WHERE q.resolved_at IS NOT NULL ORDER BY q.id LIMIT 1;
SELECT count(*) AS poll_rows_still FROM public.axs_watch_poll;

\echo '--- G. the upstream hold can now see a FAILING queue read'
-- axs_queue_claim samples the ledger for 3 upstream errors in the window. Before this
-- migration the queue''s own hold read rows the queue never wrote, so it could not back
-- off a flapping upstream.
SELECT count(*) AS acked_with_502 FROM (
  SELECT public.axs_queue_ack(q.id, 502, jsonb_build_object('status','error'))
    FROM public.axs_read_queue q WHERE q.resolved_at IS NULL ORDER BY q.id LIMIT 3) z;
SELECT count(*) FILTER (WHERE outcome='upstream_error') AS upstream_errors_in_ledger
  FROM public.axs_watch_poll WHERE checked_at > now() - interval '10 minutes';
SELECT (public.axs_queue_claim('w-ack2'))->'hold_s' AS claim_now_holds,
       (public.axs_queue_claim('w-ack2'))->'upstream_errors' AS errors_seen;

\echo '--- H. the due-list path is untouched: axs_watch_record still writes exactly one row'
SELECT count(*) AS before_record FROM public.axs_watch_poll;
SELECT (public.axs_watch_record('A5', 200, jsonb_build_object('status','ok','response_s',3.0,
          'body', jsonb_build_object('status','ok','exit_code',0,
            'event', jsonb_build_object('id','A5'), 'listings','[]'::jsonb))) - 'request_id')
        ->>'outcome' AS record_outcome;
SELECT count(*) AS after_record FROM public.axs_watch_poll;
SELECT count(*) AS rows_for_A5_never_queued FROM public.axs_watch_poll WHERE axs_event_id = 'A5';
SELECT count(*) AS settle_times_negative FROM public.axs_watch_poll
 WHERE checked_at IS NOT NULL AND checked_at < fired_at;
