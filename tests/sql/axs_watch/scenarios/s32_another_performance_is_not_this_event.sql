-- Trans-Siberian Orchestra at Toyota Center, 2026-12-11: we hold the 15:00 matinee (1579099)
-- and the 19:30 show (1579101). TicketsData echoes the right event and the right start time
-- for each, then serves BOTH the matinee's inventory (AXS event 5263). The 19:30 event
-- therefore published the matinee's seats at the matinee's prices -- $66 for seats that sold
-- at $77 and $82 on two real receipts.
--
-- The tell is inside one body: event.starts_local vs onsale.sub_events[0].date (mig
-- 20261127230000). This checks the detector, and checks that the switch ships off so the
-- feed does not change until an operator turns it on.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the switch ships off'
SELECT withhold_wrong_performance FROM public.axs_watch_config;

\echo '--- B. the matinee, asked for and served: nothing to say'
SELECT coalesce(public.axs_watch_wrong_performance(jsonb_build_object(
         'event',  jsonb_build_object('starts_local', '2026-12-11T15:00:00-06:00'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(jsonb_build_object(
                     'date', '2026-12-11 15:00:00', 'title', 'TSO - 3:00 PM'))))),
       'ok') AS matinee;

\echo '--- C. the 19:30 show served the 15:00 inventory: caught'
SELECT public.axs_watch_wrong_performance(jsonb_build_object(
         'event',  jsonb_build_object('starts_local', '2026-12-11T19:30:00-06:00'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(jsonb_build_object(
                     'date', '2026-12-11 15:00:00', 'title', 'TSO - 3:00 PM'))))) AS evening;

\echo '--- D. a half hour of slack is allowed, an hour is not'
SELECT coalesce(public.axs_watch_wrong_performance(jsonb_build_object(
         'event',  jsonb_build_object('starts_local', '2026-12-11T19:30:00-06:00'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(jsonb_build_object(
                     'date', '2026-12-11 19:00:00', 'title', 'doors'))))), 'ok') AS half_hour,
       (public.axs_watch_wrong_performance(jsonb_build_object(
         'event',  jsonb_build_object('starts_local', '2026-12-11T19:30:00-06:00'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(jsonb_build_object(
                     'date', '2026-12-11 18:30:00', 'title', 'doors'))))) IS NOT NULL) AS an_hour_caught;

\echo '--- E. a body it cannot judge is left alone'
SELECT coalesce(public.axs_watch_wrong_performance('{}'::jsonb), 'ok') AS empty_body,
       coalesce(public.axs_watch_wrong_performance(jsonb_build_object(
         'event', jsonb_build_object('starts_local', '2026-12-11T19:30:00-06:00'))), 'ok') AS no_sub_events,
       coalesce(public.axs_watch_wrong_performance(jsonb_build_object(
         'event',  jsonb_build_object('starts_local', '2026-12-11T19:30:00-06:00'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(
                     jsonb_build_object('date', '2026-12-11 15:00:00'),
                     jsonb_build_object('date', '2026-12-11 19:30:00'))))), 'ok') AS a_package,
       coalesce(public.axs_watch_wrong_performance(jsonb_build_object(
         'event',  jsonb_build_object('starts_local', 'not a timestamp'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(jsonb_build_object(
                     'date', '2026-12-11 15:00:00'))))), 'ok') AS rubbish;

\echo '--- F. the settle consults it and respects the switch'
SELECT position('axs_watch_wrong_performance' in src) > 0 AS settle_calls_detector,
       position('withhold_wrong_performance' in src) > 0 AS settle_reads_switch
  FROM (SELECT pg_get_functiondef(
          'public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure) AS src) s;
