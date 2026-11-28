-- Mig 20261128050000: the Phillies' cap of 8 is hard-coded for every game, unless the capture shows a cap of its own.
\pset footer off
INSERT INTO public.mlb_ticket_game (mlb_game_id, sport_id, game_type, game_date, game_time_utc, game_time_local, home_abbrev, away_abbrev,
       home_name, away_name, venue_name, venue_city, ticket_url, primary_seller, primary_event_id)
VALUES ('P', 1, 'R', (now() + interval '1 day')::date, now() + interval '1 day', '2027-03-30T18:45:00', 'PHI', 'NYM', 'Philadelphia Phillies', 'New York Mets',
        'Citizens Bank Park', 'Philadelphia', 'https://mlb.tickets.com/?orgid=21&agency=MLB_MPV&pid=9000001', 'provenue', '9000001'),
       ('W', 1, 'R', (now() + interval '1 day')::date, now() + interval '1 day', '2027-03-30T18:45:00', 'WSH', 'NYM', 'Washington Nationals', 'New York Mets',
        'Nationals Park', 'Washington', 'https://mlb.tickets.com/?orgid=17&agency=MLB_MPV&pid=9000002', 'provenue', '9000002');
SELECT club_order_max FROM public.provenue_watch_config;
\echo '== 1. a Phillies game whose blocks all sell whole: order_max 8; a Nationals game: none'
SELECT pid, public.provenue_capture_event($j${"listings":[
    {"section":"115","row":"12","quantity":4,"ticketPrice":50,"fee":5,"totalPrice":55,"seats":"1,2,3,4","sellableQuantities":"1,2,3,4","ticketType":"Regular Ticket"}
  ]}$j$, pid, public.provenue_watch_game(pid))->'order_max' AS order_max
  FROM (VALUES ('9000001'), ('9000002')) v(pid);
\echo '== 2. the capture shows a cap of its own: the reader wins'
SELECT public.provenue_capture_event($j${"listings":[
    {"section":"115","row":"12","quantity":12,"ticketPrice":50,"fee":5,"totalPrice":55,"seats":"1,2,3,4,5,6,7,8,9,10,11,12","sellableQuantities":"1,2,3,4,5,6","ticketType":"Regular Ticket"}
  ]}$j$, '9000001', public.provenue_watch_game('9000001'))->'order_max' AS order_max;
\echo '== 3. stored: a Phillies block of 12 that sells whole goes out as 8 + 4'
SELECT public.primary_poll_ingest('provenue', jsonb_build_array(public.provenue_capture_event($j${"listings":[
    {"section":"115","row":"12","quantity":12,"ticketPrice":50,"fee":5,"totalPrice":55,"seats":"1,2,3,4,5,6,7,8,9,10,11,12","sellableQuantities":"1,2,3,4,5,6,7,8,9,10,11,12","ticketType":"Regular Ticket"}
  ]}$j$, '9000001', public.provenue_watch_game('9000001')))) IS NOT NULL AS ingested;
SELECT source_event_id, order_max FROM public.primary_poll_event WHERE source = 'provenue';
SELECT listing_id, quantity, order_limit FROM public.primary_poll_listing WHERE source = 'provenue';
SELECT part, parts, seat_low, seat_high, quantity FROM public.primary_poll_listing_piece WHERE source = 'provenue' ORDER BY part;
