-- Operator spot check, for KING + COUNTRY at Target Center (axs 1527095), section 113 row P:
-- we published seat_low 10, seat_high 14, quantity 3, max_per_order 3 -- three seats that read
-- as adjacent. The seats are ["10","13","14"]: seat 10 alone, then 13 and 14.
--
-- primary_poll_pieces was never the problem; primary_poll_split_event only ever handed it
-- listings whose quantity EXCEEDED the order limit, because the splitter was built for
-- order limits and contiguity splitting was a side effect. 29 of that event's 346 listings
-- are non-contiguous and exactly 1 was split (mig 20261128050030).
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs','run-gap', now(), 1)
ON CONFLICT (source) DO UPDATE SET current_run='run-gap', finished_at=now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc,
        venue_name, ticket_url, poll_status, poll_ok_at, next_poll_at, poll_interval,
        last_run, watch, order_max)
VALUES ('axs','GAPS','Gapped Seats',(now()+interval '50 days')::date, now()+interval '50 days',
        'Target Center','https://www.axs.com/events/GAPS','ok', now(), now()+interval '30 min',
        interval '30 minutes','run-gap', true, 8)
ON CONFLICT (source, source_event_id) DO NOTHING;

-- the real row: three seats, two blocks, quantity equal to the order limit
INSERT INTO public.primary_poll_listing
  (source, source_event_id, listing_id, market, section, seat_row, seats, seat_low, seat_high,
   quantity, price, fee, max_per_order, obstructed, ada, general_admission, polled_at)
VALUES ('axs','GAPS','L-GAPPED','primary','113','P','["10","13","14"]'::jsonb,'10','14',
        3, 85.00, 24.11, 3, false, false, false, now()),
-- and a genuinely adjacent one of the same size, which must be left alone
       ('axs','GAPS','L-WHOLE','primary','113','Q','["3","4","5"]'::jsonb,'3','5',
        3, 85.00, 24.11, 3, false, false, false, now())
ON CONFLICT DO NOTHING;

\echo '--- A0. the fixture landed (this scenario passed vacuously once when it did not)'
SELECT count(*) AS listings_inserted FROM public.primary_poll_listing
 WHERE source='axs' AND source_event_id='GAPS';

\echo '--- A. the pieces function was always right about gaps'
SELECT part, parts, quantity, seats::text, seat_low, seat_high
  FROM public.primary_poll_pieces('["10","13","14"]'::jsonb, 3, 3) ORDER BY part;

\echo '--- B. the splitter now takes it, even though quantity does not exceed the limit'
SELECT public.primary_poll_split_event('axs','GAPS') AS pieces_written;
SELECT listing_id, part, parts, quantity, seats::text, seat_low, seat_high
  FROM public.primary_poll_listing_piece
 WHERE source='axs' AND source_event_id='GAPS' ORDER BY listing_id, part;

\echo '--- C. the CRM gets two rows for the gapped one and one for the adjacent one'
SELECT listing_id, section, seat_row, seat_low, seat_high, seats::text, quantity, max_per_order
  FROM public.v_primary_poll_listings_feed
 WHERE source='axs' AND event_id='GAPS' ORDER BY listing_id;
