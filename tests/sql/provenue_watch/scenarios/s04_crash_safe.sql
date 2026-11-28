-- Mig 20261128040000: blocks that share an id are both kept; the ledger survives pg_net's ids starting again after a
-- database restart.
\pset footer off
\echo '== 1. two blocks share section|row|first-last|type: each gets its own tag; the others keep their id; an exact repeat keeps its id, once'
SELECT x->>'id' AS id, x->>'area' AS area, x->>'all_in' AS all_in
  FROM jsonb_array_elements(public.provenue_capture_event($j${"listings":[
    {"section":"PAV","row":"1","quantity":2,"ticketPrice":50,"fee":5,"totalPrice":55,"seats":"1,4","sellableQuantities":"1,2","ticketType":"Regular Ticket","group":"Pavilion A"},
    {"section":"PAV","row":"1","quantity":3,"ticketPrice":60,"fee":6,"totalPrice":66,"seats":"1,2,4","sellableQuantities":"1,2,3","ticketType":"Regular Ticket","group":"Pavilion B"},
    {"section":"101","row":"A","quantity":2,"ticketPrice":20,"fee":3,"totalPrice":23,"seats":"1,2","sellableQuantities":"1,2","ticketType":"Regular Ticket","group":"Field"},
    {"section":"101","row":"A","quantity":2,"ticketPrice":20,"fee":3,"totalPrice":23,"seats":"1,2","sellableQuantities":"1,2","ticketType":"Regular Ticket","group":"Field"},
    {"section":"102","row":"B","quantity":2,"ticketPrice":20,"fee":3,"totalPrice":23,"seats":"3,4","sellableQuantities":"1,2","ticketType":"Regular Ticket","group":"Field"}
  ]}$j$, '1', '{}')->'listings') x
 ORDER BY x->>'id' COLLATE "C";

\echo '== 2. a read in flight when the database restarted is lost, never settled from the response that now has its id'
INSERT INTO public.mlb_ticket_game (mlb_game_id, sport_id, game_type, game_date, game_time_utc, game_time_local, home_abbrev, away_abbrev,
       home_name, away_name, venue_name, venue_city, ticket_url, primary_seller, primary_event_id)
VALUES ('A', 1, 'R', (now() + interval '1 day')::date, now() + interval '1 day', '2027-03-30T18:45:00', 'STL', 'CHC', 'St. Louis Cardinals', 'Chicago Cubs',
        'Busch Stadium', 'St. Louis', 'https://mlb.tickets.com/?orgid=10&agency=MLB_MPV&pid=9000001', 'provenue', '9000001');
INSERT INTO public.provenue_watch_poll (request_id, pid, fired_at) VALUES (7, '9000001', pg_postmaster_start_time() - interval '1 minute');
INSERT INTO net._http_response (id, status_code, content) VALUES (7, 200, '{"somebody":"else"}');
SELECT public.provenue_watch_tick();
SELECT request_id, pid, outcome, error FROM public.provenue_watch_poll ORDER BY id;

\echo '== 3. pg_net hands out id 7 again: the new read is stored beside the old row, and settles alone'
UPDATE public.provenue_watch_config SET enabled = true, daily_cap = 1000, hourly_cap = 100;
DELETE FROM net._http_response;
SELECT setval(pg_get_serial_sequence('net.sent', 'id'), 6);
UPDATE public.provenue_watch_poll SET fired_at = fired_at - interval '1 hour';
SELECT public.provenue_watch_tick() - 'captures_remaining';
INSERT INTO net._http_response (id, status_code, content)
VALUES (7, 200, '{"listings":[{"section":"101","row":"A","quantity":2,"ticketPrice":20,"fee":3,"totalPrice":23,"seats":"1,2","sellableQuantities":"1,2","ticketType":"Regular Ticket"}]}');
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT request_id, pid, outcome, error, listings FROM public.provenue_watch_poll ORDER BY id;
