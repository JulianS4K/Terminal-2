-- Mig 20261128030000: a ProVenue event carries the club's order cap, as AXS and the Timberwolves do, when a block
-- shows it; and the listing limits and the split follow the event's cap.
\pset footer off
\echo '== 1. a block of 12 that sells at most 9: the cap is 9, the smallest order 1'
SELECT e->'order_min' AS order_min, e->'order_max' AS order_max
  FROM public.provenue_capture_event($j${"listings":[
    {"section":"10","row":"A","quantity":12,"ticketPrice":30,"fee":5,"totalPrice":35,"seats":"1,2,3,4,5,6,7,8,9,10,11,12","sellableQuantities":"1,2,3,4,5,6,7,8,9","ticketType":"Regular Ticket"},
    {"section":"11","row":"B","quantity":4,"ticketPrice":30,"fee":5,"totalPrice":35,"seats":"1,2,3,4","sellableQuantities":"1,2,3,4","ticketType":"Regular Ticket"}
  ]}$j$, '1', '{}') e;

\echo '== 2. every block sells whole: no cap is known'
SELECT e->'order_min' AS order_min, e->'order_max' AS order_max
  FROM public.provenue_capture_event($j${"listings":[
    {"section":"10","row":"A","quantity":30,"ticketPrice":30,"fee":5,"totalPrice":35,"seats":"","sellableQuantities":"2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30","ticketType":"Regular Ticket"}
  ]}$j$, '1', '{}') e;

\echo '== 3. no listings: no limit'
SELECT e ? 'order_min' AS has_min, e ? 'order_max' AS has_max FROM public.provenue_capture_event('{"listings":[]}', '1', '{}') e;

\echo '== 4. stored: the event carries the cap; the block of 12 is sent as 9 + 3, the block of 4 whole'
SELECT public.primary_poll_ingest('provenue', jsonb_build_array(public.provenue_capture_event($j${"listings":[
    {"section":"10","row":"A","quantity":12,"ticketPrice":30,"fee":5,"totalPrice":35,"seats":"1,2,3,4,5,6,7,8,9,10,11,12","sellableQuantities":"1,2,3,4,5,6,7,8,9","ticketType":"Regular Ticket"},
    {"section":"11","row":"B","quantity":4,"ticketPrice":30,"fee":5,"totalPrice":35,"seats":"1,2,3,4","sellableQuantities":"1,2,3,4","ticketType":"Regular Ticket"}
  ]}$j$, '9000001', '{"name":"Orioles at Rays","local_date":"2027-03-30","local_time":"18:45"}'))) - 'run' IS NOT NULL AS ingested;
SELECT source_event_id, order_min, order_max FROM public.primary_poll_event WHERE source = 'provenue';
SELECT listing_id, quantity, max_per_order, order_limit FROM public.primary_poll_listing WHERE source = 'provenue' ORDER BY listing_id COLLATE "C";
SELECT listing_id, part, parts, seat_low, seat_high, quantity FROM public.primary_poll_listing_piece WHERE source = 'provenue' ORDER BY listing_id COLLATE "C", part;
