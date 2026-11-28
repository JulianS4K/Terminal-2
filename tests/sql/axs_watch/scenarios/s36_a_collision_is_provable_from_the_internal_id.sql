-- Operator 2026-11-28: "add that column, if an event sends wrong info and is caught add it to
-- the once a day poller and stop sending listings to crm but monitor, then replace with a new
-- one" and "isnt the title and time and date a give away?"
--
-- Three collisions are proven in prod, all found the hard way:
--   Trans-Siberian Orchestra 1579099/1579101   same show, two performances
--   Disney Descendants 1374728 <- for KING + COUNTRY 1519444   two DIFFERENT shows
--   PBR 12/20 1583731 <- PBR 12/19 1583729     388 of 388 listings identical
--
-- Every listing carries AXS's own internal event id, so a collision is two of our
-- source_event_ids pointing at one of theirs -- no timing, no tolerance. The event block
-- (title and starts_local) is the trustworthy half and the onsale block is the suspect half,
-- so both checks anchor on the event.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the internal id is read from the onsale, else from the listings'
SELECT public.axs_watch_internal_event_id(jsonb_build_object('onsale',
         jsonb_build_object('flags', jsonb_build_object('events', jsonb_build_array('5263'))))) AS from_onsale,
       public.axs_watch_internal_event_id(jsonb_build_object('listings',
         jsonb_build_array(jsonb_build_object('event_id','17673')))) AS from_listings,
       coalesce(public.axs_watch_internal_event_id('{}'::jsonb),'(none)') AS empty_body;

\echo '--- B. the show-name check, against all seven real title pairs'
SELECT public.axs_watch_wrong_show(jsonb_build_object(
         'event', jsonb_build_object('title','Disney Descendants, ZOMBIES & Camp Rock: Worlds Collide Concert Tour'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(
           jsonb_build_object('title','for KING + COUNTRY'))))) AS disney_vs_fkc,
       public.axs_watch_wrong_show(jsonb_build_object(
         'event', jsonb_build_object('title','PBR: PENDLETON WHISKY VELOCITY TOUR - 12/20'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(
           jsonb_build_object('title','PBR: PENDLETON WHISKY VELOCITY TOUR - 12/19'))))) AS pbr_1220_vs_1219,
       public.axs_watch_wrong_show(jsonb_build_object(
         'event', jsonb_build_object('title','Trans-Siberian Orchestra'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(
           jsonb_build_object('title','Trans-Siberian Orchestra - 3:00 PM'))))) AS tso_same_show,
       public.axs_watch_wrong_show(jsonb_build_object(
         'event', jsonb_build_object('title','NCAA DI W Bball Las Vegas Region TBD Elite 8'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(
           jsonb_build_object('title','NCAA DI W Bball Las Vegas Region TBD Elite 8'))))) AS ncaa_same,
       public.axs_watch_wrong_show(jsonb_build_object(
         'event', jsonb_build_object('title','2027 BNP Paribas Open - Session 20 - Friday Eve Session'),
         'onsale', jsonb_build_object('sub_events', jsonb_build_array(
           jsonb_build_object('title','Session 20 - Friday Eve Session - 03/12/2027'))))) AS indian_wells_same,
       public.axs_watch_wrong_show('{}'::jsonb) AS empty_body;

\echo '--- C. a collision parks the impostor: daily band, no listings, still watched'
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs','run-col', now(), 2)
ON CONFLICT (source) DO UPDATE SET current_run='run-col', finished_at=now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc,
        venue_name, ticket_url, poll_status, next_poll_at, poll_interval, last_run, watch,
        axs_event_internal)
VALUES ('axs','GOOD','Real Show',(now()+interval '30 days')::date, now()+interval '30 days',
        'Big Arena','https://www.axs.com/events/GOOD','ok', now()+interval '1 hour',
        interval '60 minutes','run-col', true, '9999'),
       ('axs','IMPOSTOR','Other Show',(now()+interval '31 days')::date, now()+interval '31 days',
        'Big Arena','https://www.axs.com/events/IMPOSTOR','pending', now()-interval '5 min',
        interval '60 minutes','run-col', true, NULL)
ON CONFLICT (source, source_event_id) DO NOTHING;

SELECT (public.axs_watch_settle_one('IMPOSTOR', 200, jsonb_build_object('body', jsonb_build_object(
          'status','ok','exit_code',0,
          'event', jsonb_build_object('id','IMPOSTOR','title','Other Show',
                   'starts_local','2026-12-02T19:00:00-06:00',
                   'venue', jsonb_build_object('name','Big Arena')),
          'onsale', jsonb_build_object(
                   'flags', jsonb_build_object('events', jsonb_build_array('9999')),
                   'sub_events', jsonb_build_array(jsonb_build_object(
                     'date','2026-12-03 19:00:00','title','Real Show'))),
          'listings','[]'::jsonb)), false, NULL, false, 'test'))->>'outcome' AS outcome;

SELECT source_event_id, axs_event_internal, collision_paused, cadence_pinned,
       (poll_interval >= (SELECT no_tickets_every FROM axs_watch_config)) AS daily_band,
       watch AS still_monitored, listing_count
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='IMPOSTOR';

\echo '--- D. the CRM sees the reason, and no listings'
SELECT listings_available, listings_withheld FROM public.v_primary_poll_events_feed
 WHERE source='axs' AND event_id='IMPOSTOR';
SELECT count(*) AS listing_rows FROM public.v_primary_poll_listings_feed
 WHERE source='axs' AND event_id='IMPOSTOR';

\echo '--- E. the collision is visible, and a later read cannot un-park it'
SELECT axs_event_internal, events, source_event_ids, already_paused
  FROM public.v_axs_event_collisions;
SELECT (public.axs_watch_settle_one('IMPOSTOR', 200, jsonb_build_object('body', jsonb_build_object(
          'status','ok','exit_code',0,
          'event', jsonb_build_object('id','IMPOSTOR','title','Other Show'),
          'onsale', jsonb_build_object('flags', jsonb_build_object('events', jsonb_build_array('9999'))),
          'listings','[]'::jsonb)), false, NULL, false, 'test')) IS NOT NULL AS second_read_ran;
SELECT collision_paused, cadence_pinned,
       (poll_interval >= (SELECT no_tickets_every FROM axs_watch_config)) AS still_daily_band
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='IMPOSTOR';

\echo '--- F. the innocent twin is untouched'
SELECT collision_paused, watch, poll_interval = interval '60 minutes' AS keeps_its_band
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='GOOD';

\echo '--- G. the same id at a DIFFERENT venue is not a collision (mig 20261128060030)'
-- AXS reuses its internal ids per box office. Found when the mechanism's first new report was
-- 2393 shared by Sabrina Cast Reunion at Royal Oak Music Theatre and Jhene Aiko at T-Mobile
-- Arena -- different venues, 40 listings against 620, nothing shared.
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc,
        venue_name, ticket_url, poll_status, next_poll_at, poll_interval, last_run, watch,
        axs_event_internal)
VALUES ('axs','FARAWAY','Other Venue Show',(now()+interval '60 days')::date, now()+interval '60 days',
        'A Different Arena','https://www.axs.com/events/FARAWAY','ok', now()+interval '1 hour',
        interval '60 minutes','run-col', true, '9999')
ON CONFLICT (source, source_event_id) DO NOTHING;
SELECT axs_event_internal, venue_name, events, source_event_ids
  FROM public.v_axs_event_collisions ORDER BY venue_name;
