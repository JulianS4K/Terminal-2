-- Accessible seats are stored but not sent (mig 20261125180000, operator "also dont send out ADA seats too").
-- Both signals are tested: the ada flag AND ticket_type = 'ACCESSIBLE'. On AXS only 17 of 1,394 ACCESSIBLE
-- listings carried ada = true, so a filter on ada alone would have let 93% of them through.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the default'
SELECT send_ada, split_over_limit FROM public.primary_poll_config;

-- one event, freshly polled, with one listing of each kind
UPDATE public.primary_poll_config SET split_over_limit = false;   -- pieces are s02; this is about withholding
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-ada', now(), 1)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-ada', finished_at = now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_ok_at, next_poll_at, poll_interval, last_run, order_min, order_max)
VALUES ('axs', '901', 'Accessible Test Show', current_date + 30, now() + interval '30 days', 'Big Arena',
        'https://www.axs.com/events/901/tickets', 'ok', now(), now() + interval '1 hour', interval '1 hour',
        'run-ada', 1, 4)
ON CONFLICT (source, source_event_id) DO UPDATE
   SET poll_status='ok', poll_ok_at=now(), next_poll_at=now()+interval '1 hour', last_run='run-ada';
INSERT INTO public.primary_poll_listing (source, source_event_id, listing_id, market, section, quantity,
        price, ticket_type, general_admission, obstructed, ada)
VALUES ('axs','901','L-plain',      'primary','Floor 1',  10, 100, 'STANDARD',   false, false, false),
       ('axs','901','L-ada-flag',   'primary','Row 5',      4,  90, 'STANDARD',   false, false, true),
       ('axs','901','L-accessible', 'primary','Accessible', 6,  80, 'ACCESSIBLE', false, false, false),
       ('axs','901','L-both',       'primary','Acc 70',     2,  70, 'ACCESSIBLE', false, false, true),
       ('axs','901','L-obstructed', 'primary','Side',       3,  60, 'STANDARD',   false, true,  false),
       ('axs','901','L-ga',         'primary','GA',       500,  50, 'STANDARD',   true,  false, false)
ON CONFLICT (source, source_event_id, listing_id) DO NOTHING;

\echo '--- B. stored: all six, including the accessible ones'
SELECT listing_id, ticket_type, ada, obstructed, general_admission, quantity
  FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='901' ORDER BY listing_id;

\echo '--- C. sent: the plain and the GA only — ada flag, ACCESSIBLE type and obstructed are all withheld'
SELECT listing_id, ticket_type, ada, quantity
  FROM public.v_primary_poll_listings_feed WHERE source='axs' AND event_id='901' ORDER BY listing_id;

\echo '--- D. send_ada = true puts the accessible ones back (obstructed stays withheld)'
UPDATE public.primary_poll_config SET send_ada = true;
SELECT listing_id, ticket_type, ada
  FROM public.v_primary_poll_listings_feed WHERE source='axs' AND event_id='901' ORDER BY listing_id;

\echo '--- E. and off again'
UPDATE public.primary_poll_config SET send_ada = false;
SELECT count(*) AS sent_rows FROM public.v_primary_poll_listings_feed WHERE source='axs' AND event_id='901';
