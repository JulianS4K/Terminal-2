-- A failed read leaves the last good capture alone; two in a row discard it (mig 20261126013000).
-- Operator 2026-11-26: "no destroy inventory if 2 reads fail back to back".
-- The bug: primary_poll_ingest deleted an event's listings UNCONDITIONALLY before deciding whether there was
-- anything to put back. Survivable while an upstream is up or down; pathological while it FLAPS, because it
-- ratchets — a good read restores, the next bad read wipes, and the store walks to zero instead of to stale.
-- On prod, with AXS flapping, the axs store fell 46,030 -> 16,079 rows in 32 minutes.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-cap', now(), 1)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-cap', finished_at = now();

\echo '--- A. the threshold, as the operator set it'
SELECT purge_after_failures FROM public.primary_poll_config;

\echo '--- B. a good read: the capture is stored, failed_reads is 0'
SELECT public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
   'id','C1','name','Flapping Game','local_date',(current_date + 20)::text,'venue','Big Arena',
   'url','https://www.axs.com/events/C1','ok',true,
   'listings', jsonb_build_array(
     jsonb_build_object('id','L1','market','primary','section','101','row','A','qty',2,'price',100,'all_in',115),
     jsonb_build_object('id','L2','market','primary','section','102','row','B','qty',3,'price',80,'all_in',92))))) AS ingest_ok;
SELECT source_event_id AS id, poll_status, listing_count, failed_reads,
       (SELECT count(*) FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='C1') AS rows_stored
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C1';

\echo '--- C. ONE failed read: the capture SURVIVES. Before this migration both numbers went to 0.'
SELECT public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
   'id','C1','name','Flapping Game','local_date',(current_date + 20)::text,'venue','Big Arena',
   'url','https://www.axs.com/events/C1','ok',false,'error','unavailable'))) AS ingest_fail_1;
SELECT source_event_id AS id, poll_status, listing_count, failed_reads,
       (SELECT count(*) FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='C1') AS rows_stored
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C1';

\echo '--- D. and it is still NOT served, because the feed requires poll_status = ok'
SELECT count(*) AS rows_in_feed FROM public.v_primary_poll_listings_feed WHERE source='axs' AND event_id='C1';

\echo '--- E. a SECOND failure back to back: now the capture goes, and listing_count goes with it'
SELECT public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
   'id','C1','name','Flapping Game','local_date',(current_date + 20)::text,'venue','Big Arena',
   'url','https://www.axs.com/events/C1','ok',false,'error','unavailable'))) AS ingest_fail_2;
SELECT source_event_id AS id, poll_status, listing_count, failed_reads,
       (SELECT count(*) FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='C1') AS rows_stored
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C1';

\echo '--- F. THE RATCHET IS GONE: ok, fail, ok, fail, ok, fail never loses the capture'
SELECT public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
   'id','C2','name','Flapper Two','local_date',(current_date + 20)::text,'venue','Big Arena',
   'url','https://www.axs.com/events/C2','ok',true,
   'listings', jsonb_build_array(jsonb_build_object('id','M1','market','primary','section','1','row','A','qty',4,'price',50,'all_in',58))))) AS seed;
DO $$
DECLARE i integer;
BEGIN
  FOR i IN 1..3 LOOP
    PERFORM public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
      'id','C2','name','Flapper Two','local_date',(current_date + 20)::text,'venue','Big Arena',
      'url','https://www.axs.com/events/C2','ok',false,'error','unavailable')));
    PERFORM public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
      'id','C2','name','Flapper Two','local_date',(current_date + 20)::text,'venue','Big Arena',
      'url','https://www.axs.com/events/C2','ok',true,
      'listings', jsonb_build_array(jsonb_build_object('id','M1','market','primary','section','1','row','A','qty',4,'price',50,'all_in',58)))));
  END LOOP;
END $$;
SELECT source_event_id AS id, poll_status, listing_count, failed_reads,
       (SELECT count(*) FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='C2') AS rows_stored
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C2';

\echo '--- G. a success resets the count, so two failures that straddle a success do NOT purge'
SELECT public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
   'id','C2','name','Flapper Two','local_date',(current_date + 20)::text,'venue','Big Arena',
   'url','https://www.axs.com/events/C2','ok',false,'error','unavailable'))) AS fail_after_ok;
SELECT failed_reads, listing_count,
       (SELECT count(*) FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='C2') AS rows_stored
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C2';

\echo '--- H. purge_after_failures = 1 restores the old behaviour exactly'
UPDATE public.primary_poll_config SET purge_after_failures = 1;
SELECT public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
   'id','C3','name','Old Behaviour','local_date',(current_date + 20)::text,'venue','Big Arena',
   'url','https://www.axs.com/events/C3','ok',true,
   'listings', jsonb_build_array(jsonb_build_object('id','N1','market','primary','section','9','row','Z','qty',1,'price',10,'all_in',12))))) AS seed3;
SELECT public.primary_poll_ingest('axs', jsonb_build_array(jsonb_build_object(
   'id','C3','name','Old Behaviour','local_date',(current_date + 20)::text,'venue','Big Arena',
   'url','https://www.axs.com/events/C3','ok',false,'error','unavailable'))) AS one_failure_purges;
SELECT failed_reads, listing_count,
       (SELECT count(*) FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='C3') AS rows_stored
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C3';
UPDATE public.primary_poll_config SET purge_after_failures = 2;

\echo '--- I. the threshold cannot be set to zero'
CREATE TEMP TABLE _b (tried integer, outcome text);
DO $$
DECLARE v integer;
BEGIN
  FOREACH v IN ARRAY ARRAY[0, -1, 1, 2] LOOP
    BEGIN
      UPDATE public.primary_poll_config SET purge_after_failures = v;
      INSERT INTO _b VALUES (v, 'accepted');
    EXCEPTION WHEN check_violation THEN
      INSERT INTO _b VALUES (v, 'refused');
    END;
  END LOOP;
END $$;
SELECT tried, outcome FROM _b ORDER BY tried;
SELECT purge_after_failures AS left_at FROM public.primary_poll_config;
