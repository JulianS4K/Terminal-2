-- Operator 2026-11-28: "build the durable paused column".
--
-- The pause shipped in mig 20261127213000 was cadence_pinned + a one-day band, and the settle
-- recomputes BOTH on every successful read. The two Trans-Siberian shows came un-paused twice
-- on 2026-11-28 because of it -- once after a forced re-poll, republishing the matinee's
-- prices against the 19:30 show for about an hour, and once on an ordinary scheduled read.
--
-- So the test that matters is not "does pausing withhold the listings" but "does it still
-- withhold them AFTER a successful read". That is the step the old mechanism failed.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs','run-pause', now(), 1)
ON CONFLICT (source) DO UPDATE SET current_run='run-pause', finished_at=now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc,
        venue_name, ticket_url, poll_status, next_poll_at, poll_interval, last_run, watch)
VALUES ('axs','PAUSEME','Paused Show',(now()+interval '40 days')::date, now()+interval '40 days',
        'Big Arena','https://www.axs.com/events/PAUSEME','pending', now()-interval '5 min',
        interval '30 minutes','run-pause', true)
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- A. it reads and publishes normally to begin with'
SELECT (public.axs_watch_settle_one('PAUSEME', 200, jsonb_build_object('body', jsonb_build_object(
          'status','ok','exit_code',0,
          'event', jsonb_build_object('id','PAUSEME','title','Paused Show'),
          'listings', jsonb_build_array(jsonb_build_object(
            'kind','primary','status','Open','section','A','row','1',
            'seats', (SELECT jsonb_agg(g::text) FROM generate_series(1,40) g),'quantity',40,'offer_id','O1',
            'pricing', jsonb_build_object('face',50,'fees_total',10,'all_in',60))))),
          false, NULL, false, 'test'))->>'outcome' AS outcome;
SELECT listings_available, coalesce(listings_withheld,'(sending)') AS feed_state
  FROM public.v_primary_poll_events_feed WHERE source='axs' AND event_id='PAUSEME';
SELECT count(*) AS listing_rows FROM public.v_primary_poll_listings_feed
 WHERE source='axs' AND event_id='PAUSEME';

\echo '--- B. the operator pauses it'
UPDATE public.primary_poll_event SET paused = true
 WHERE source='axs' AND source_event_id='PAUSEME';
SELECT listings_available, listings_withheld FROM public.v_primary_poll_events_feed
 WHERE source='axs' AND event_id='PAUSEME';
SELECT count(*) AS listing_rows FROM public.v_primary_poll_listings_feed
 WHERE source='axs' AND event_id='PAUSEME';

\echo '--- C. THE TEST: a successful read must not undo it'
SELECT (public.axs_watch_settle_one('PAUSEME', 200, jsonb_build_object('body', jsonb_build_object(
          'status','ok','exit_code',0,
          'event', jsonb_build_object('id','PAUSEME','title','Paused Show'),
          'listings', jsonb_build_array(jsonb_build_object(
            'kind','primary','status','Open','section','A','row','1',
            'seats', (SELECT jsonb_agg(g::text) FROM generate_series(1,40) g),'quantity',40,'offer_id','O1',
            'pricing', jsonb_build_object('face',50,'fees_total',10,'all_in',60))))),
          false, NULL, false, 'test'))->>'outcome' AS second_read;
SELECT paused, listing_count > 0 AS capture_kept
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='PAUSEME';
SELECT listings_available, listings_withheld FROM public.v_primary_poll_events_feed
 WHERE source='axs' AND event_id='PAUSEME';
SELECT count(*) AS listing_rows FROM public.v_primary_poll_listings_feed
 WHERE source='axs' AND event_id='PAUSEME';

\echo '--- D. and unpausing restores it, without needing a fresh read'
UPDATE public.primary_poll_event SET paused = false
 WHERE source='axs' AND source_event_id='PAUSEME';
SELECT listings_available, coalesce(listings_withheld,'(sending)') AS feed_state
  FROM public.v_primary_poll_events_feed WHERE source='axs' AND event_id='PAUSEME';
SELECT count(*) AS listing_rows FROM public.v_primary_poll_listings_feed
 WHERE source='axs' AND event_id='PAUSEME';
