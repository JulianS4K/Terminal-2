-- Three operator rules (mig 20261126065000):
--   1. a cancelled event is retired, whatever its date
--   2. "no tickets are currently available" retires it only within no_tickets_retire_days
--   3. GA-only with more than ga_slow_min_tickets GA TICKETS reads every ga_slow_every
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by)
VALUES (920001, 'Dead Letter Arena', 0, true, true, 'scenario', 'test');
UPDATE public.axs_watch_config SET keep_regex = NULL, target_events = 50, reader = 'worker';

\echo '--- A. the knobs as seeded'
SELECT no_tickets_retire_days, ga_slow_every, ga_slow_min_tickets, no_tickets_every
  FROM public.axs_watch_config;

-- D1 cancelled and near. D2 cancelled and far. D3 no-tickets and near. D4 no-tickets and far.
INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, true, 'On Sale', v.title, 'Music', 920001, 'Dead Letter Arena', 'Denver', 'CO',
       to_char(now() + make_interval(days => v.days), 'YYYY-MM-DD"T"HH24:MI:SS'),
       now() + make_interval(days => v.days), 'America/Denver',
       'https://www.axs.com/events/' || v.id
  FROM (VALUES (9300001,'Cancelled Near',3), (9300002,'Cancelled Far',100),
               (9300003,'No Tickets Near',3), (9300004,'No Tickets Far',100),
               (9300005,'Healthy',30)) AS v(id, title, days);
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_in;
SELECT count(*) AS on_the_list FROM public.primary_poll_event WHERE source='axs';

\echo '--- B. the four dead-ish reads land by the WORKER path (axs_watch_record)'
SELECT v.ev AS id,
       (public.axs_watch_record(v.ev, 200,
          jsonb_build_object('status','ok','response_s',2.0,
            'body', jsonb_build_object('status','error','exit_code',1,'error', v.e)))
        - 'request_id')->>'outcome' AS outcome
  FROM (VALUES ('9300001','This event has been cancelled.'),
               ('9300002','This event has been cancelled.'),
               ('9300003','No tickets are currently available for this event.'),
               ('9300004','No tickets are currently available for this event.')) v(ev, e);
SELECT count(*) AS poll_rows_written FROM public.axs_watch_poll WHERE axs_event_id LIKE '93000%';

\echo '--- C. axs_watch_event_dead: cancelled always, no-tickets only inside the window'
SELECT t.source_event_id AS id, left(t.name,16) AS name, t.event_date - current_date AS days_out,
       public.axs_watch_event_dead(t.source_event_id, t.event_date) AS dead
  FROM public.primary_poll_event t WHERE t.source='axs' ORDER BY t.source_event_id;

\echo '--- D. a dead read also drops the cadence at once, so the wait costs little'
SELECT source_event_id AS id, poll_interval,
       poll_interval = (SELECT not_on_sale_every FROM public.axs_watch_config) AS on_the_slow_rule
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id IN ('9300001','9300003')
 ORDER BY 1;

\echo '--- E. the fill retires the dead ones and does NOT hand their places back'
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_retires;
SELECT coalesce(string_agg(source_event_id, ',' ORDER BY source_event_id), '(none)') AS still_listed
  FROM public.primary_poll_event WHERE source='axs';
SELECT axs_event_id AS id, note FROM public.axs_watch_audit
 WHERE action='retire' AND note='over_or_cancelled' ORDER BY 1;

\echo '--- F. a second fill does not resurrect them (the candidate guard)'
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_again;
SELECT coalesce(string_agg(source_event_id, ',' ORDER BY source_event_id), '(none)') AS still_listed
  FROM public.primary_poll_event WHERE source='axs';

\echo '--- G. nor does the catalogue publish them'
SELECT (public.axs_catalogue_fill()) AS catalogue;
SELECT coalesce(string_agg(event_id, ',' ORDER BY event_id), '(none)') AS in_the_api_feed
  FROM public.v_primary_poll_events_feed WHERE source='axs';

\echo '--- G2. the QUEUE path writes NO poll row, so the check must work off poll_error'
-- axs_queue_ack calls axs_watch_settle_one directly and never touches axs_watch_poll. A
-- dead-event check resting on the ledger alone would go blind the day the queue is on.
INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
VALUES (9300006, true, 'On Sale', 'Cancelled Via Queue', 'Music', 920001, 'Dead Letter Arena',
        'Denver','CO', to_char(now() + interval '3 days','YYYY-MM-DD"T"HH24:MI:SS'),
        now() + interval '3 days', 'America/Denver', 'https://www.axs.com/events/9300006');
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_adds_it;
-- settle only: no axs_watch_poll row, exactly as axs_queue_ack behaves
SELECT (public.axs_watch_settle_one('9300006', 200,
          jsonb_build_object('body', jsonb_build_object('status','error','exit_code',1,
            'error','This event has been cancelled.')), false, NULL, false, 'queue'))->>'outcome'
       AS settled_without_a_poll_row;
SELECT count(*) AS poll_rows_for_it FROM public.axs_watch_poll WHERE axs_event_id = '9300006';
SELECT left(poll_error, 32) AS stored_error,
       public.axs_watch_event_dead('9300006', event_date) AS dead_anyway
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9300006';

\echo '--- H. rule 3: GA-only over 100 TICKETS moves to 2 hours; ADA does not disqualify'
-- The GA profile is computed from the listings THIS read wrote, so the fixture has to send
-- them through the read payload: primary_poll_ingest replaces an event's listings wholesale
-- on a good read, so rows inserted by hand beforehand are gone by the time it is computed.
INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, true, 'On Sale', v.nm, 'Music', 920001, 'Dead Letter Arena', 'Denver', 'CO',
       to_char(now() + interval '30 days', 'YYYY-MM-DD"T"HH24:MI:SS'),
       now() + interval '30 days', 'America/Denver', 'https://www.axs.com/events/' || v.id
  FROM (VALUES (9400001,'GA deep'), (9400002,'GA deep plus ADA'),
               (9400003,'GA shallow'), (9400004,'GA plus reserved')) AS v(id, nm);
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_adds_the_ga_events;

-- a GA block of 500, a GA block of 500 beside an ADA listing, a GA block of 40,
-- and a GA block of 500 beside an ordinary reserved listing
SELECT v.ev AS id,
       (public.axs_watch_record(v.ev, 200, jsonb_build_object(
          'status','ok','response_s',3.0,
          'body', jsonb_build_object('status','ok','exit_code',0,
            'event', jsonb_build_object('id', v.ev),
            'listings', v.ls))) - 'request_id')->>'outcome' AS outcome
  FROM (VALUES
    ('9400001', jsonb_build_array(
       jsonb_build_object('kind','primary','section','General Admission','quantity',500,
         'general_admission',true,'status','Available',
         'pricing', jsonb_build_object('face',40,'fees_total',6,'tax',0,'all_in',46)))),
    ('9400002', jsonb_build_array(
       jsonb_build_object('kind','primary','section','General Admission','quantity',500,
         'general_admission',true,'status','Available',
         'pricing', jsonb_build_object('face',40,'fees_total',6,'tax',0,'all_in',46)),
       jsonb_build_object('kind','primary','section','Accessible 70','row','70','quantity',6,
         'seat_type','ADA','status','Available',
         'pricing', jsonb_build_object('face',40,'fees_total',6,'tax',0,'all_in',46)))),
    ('9400003', jsonb_build_array(
       jsonb_build_object('kind','primary','section','General Admission','quantity',40,
         'general_admission',true,'status','Available',
         'pricing', jsonb_build_object('face',40,'fees_total',6,'tax',0,'all_in',46)))),
    ('9400004', jsonb_build_array(
       jsonb_build_object('kind','primary','section','General Admission','quantity',500,
         'general_admission',true,'status','Available',
         'pricing', jsonb_build_object('face',40,'fees_total',6,'tax',0,'all_in',46)),
       jsonb_build_object('kind','primary','section','101','row','A','seats',jsonb_build_array('1','2'),
         'quantity',8,'status','Available',
         'pricing', jsonb_build_object('face',40,'fees_total',6,'tax',0,'all_in',46))))
  ) v(ev, ls);

\echo '--- H2. what the reads actually stored'
SELECT source_event_id AS id, count(*) AS listings,
       count(*) FILTER (WHERE general_admission) AS ga,
       count(*) FILTER (WHERE coalesce(ada,false)) AS ada,
       count(*) FILTER (WHERE NOT coalesce(general_admission,false)
                          AND NOT coalesce(ada,false)) AS reserved_non_ada,
       sum(quantity) FILTER (WHERE general_admission) AS ga_tickets
  FROM public.primary_poll_listing WHERE source='axs' AND source_event_id LIKE '94000%'
 GROUP BY 1 ORDER BY 1;

\echo '--- I. only the two deep-GA events are slowed, and only to 2 hours'
SELECT t.source_event_id AS id, left(t.name,18) AS name, t.ga_slow, t.poll_interval
  FROM public.primary_poll_event t
 WHERE t.source='axs' AND t.source_event_id LIKE '94000%' ORDER BY 1;

\echo '--- J. the 3-arg cadence only ever SLOWS: a day-of event is 30 min, not faster'
SELECT public.axs_watch_cadence_every(now() + interval '2 days', NULL, false) AS band_normal,
       public.axs_watch_cadence_every(now() + interval '2 days', NULL, true)  AS band_ga_slow,
       public.axs_watch_cadence_every(now() + interval '2 days', NULL, true)
         >= public.axs_watch_cadence_every(now() + interval '2 days', NULL, false) AS never_faster;

\echo '--- K. the gauge counts the slowed events at their slowed rate'
SELECT (public.axs_watch_cadence_demand()) - 'usable_per_hour' - 'daily_cap'
         - 'pct_of_throughput' - 'pct_of_daily_cap' - 'fits' AS demand;

\echo '--- L. no-tickets BEYOND the retire window is read once a day, not every 6 hours'
-- Inside the window it is retired (section E). Beyond it, it stays but drops to
-- no_tickets_every, while "not on sale" and "coming soon" keep the 6-hour rule because
-- their on-sale moment can arrive at any hour (mig 20261126070000).
INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, true, 'On Sale', v.nm, 'Music', 920001, 'Dead Letter Arena', 'Denver', 'CO',
       to_char(now() + interval '60 days', 'YYYY-MM-DD"T"HH24:MI:SS'),
       now() + interval '60 days', 'America/Denver', 'https://www.axs.com/events/' || v.id
  FROM (VALUES (9500001,'No Tickets Far Off'), (9500002,'Not On Sale Far Off')) AS v(id, nm);
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_adds_them;
SELECT v.ev AS id,
       (public.axs_watch_record(v.ev, 200, jsonb_build_object('status','ok','response_s',2.0,
          'body', jsonb_build_object('status','error','exit_code',1,'error', v.e)))
        - 'request_id')->>'outcome' AS outcome
  FROM (VALUES ('9500001','No tickets are currently available for this event.'),
               ('9500002','Tickets are not currently on sale for this event.')) v(ev, e);
SELECT t.source_event_id AS id, left(t.name,20) AS name, t.poll_interval,
       t.poll_interval = (SELECT no_tickets_every FROM public.axs_watch_config) AS on_the_daily_rule,
       t.poll_interval = (SELECT not_on_sale_every FROM public.axs_watch_config) AS on_the_6h_rule,
       public.axs_watch_event_dead(t.source_event_id, t.event_date) AS dead
  FROM public.primary_poll_event t
 WHERE t.source='axs' AND t.source_event_id LIKE '95000%' ORDER BY 1;
