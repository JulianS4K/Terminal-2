-- Mig 20261128020000: a seat that is not a number parses, and one response the settle cannot take fails only
-- that read, not the tick.
\pset footer off
\echo '== 1. seats: numbers numerically; the Rays companion seats 1C,2C as text; numbered seats keep their old id'
SELECT x->>'id' AS id, x->>'seat_low' AS lo, x->>'seat_high' AS hi, x->'seats' AS seats, x->>'ada' AS ada
  FROM jsonb_array_elements(public.provenue_capture_event($j${"listings":[
    {"section":"CHALK126","row":"C","quantity":2,"ticketPrice":40,"fee":5,"totalPrice":45,"seats":"1C,2C","sellableQuantities":"2",
     "ticketType":"Single Game Ticket accessible this is a companion seat in an ada compliant location."},
    {"section":"304","row":"J","quantity":3,"ticketPrice":15,"fee":2,"totalPrice":17,"seats":"10,9,11","sellableQuantities":"1,2,3","ticketType":"Regular Ticket"},
    {"section":"305","row":"K","quantity":3,"ticketPrice":15,"fee":2,"totalPrice":17,"seats":"2C,10,1","sellableQuantities":"1,2,3","ticketType":"Regular Ticket"}
  ]}$j$, '1', '{}')->'listings') x
 ORDER BY x->>'id' COLLATE "C";

\echo '== 2. two games fire; the settle of one throws'
INSERT INTO public.mlb_ticket_game (mlb_game_id, sport_id, game_type, game_date, game_time_utc, game_time_local, home_abbrev, away_abbrev,
       home_name, away_name, venue_name, venue_city, ticket_url, primary_seller, primary_event_id, tevo_event_id)
VALUES
 ('A', 1, 'R', (now() + interval '1 day')::date, now() + interval '1 day', '2027-03-30T18:45:00', 'TB', 'BAL', 'Tampa Bay Rays', 'Baltimore Orioles',
  'Tropicana Field', 'St. Petersburg', 'https://mlb.tickets.com/?orgid=1&agency=MLB_MPV&pid=9000001', 'provenue', '9000001', 1),
 ('B', 1, 'R', (now() + interval '2 days')::date, now() + interval '2 days', '2027-03-31T18:45:00', 'TB', 'BAL', 'Tampa Bay Rays', 'Baltimore Orioles',
  'Tropicana Field', 'St. Petersburg', 'https://mlb.tickets.com/?orgid=1&agency=MLB_MPV&pid=9000002', 'provenue', '9000002', 2);
UPDATE public.provenue_watch_config SET enabled = true, daily_cap = 1000, hourly_cap = 100;
SELECT public.provenue_watch_tick() - 'captures_remaining';
-- a parse fault we have not met yet: the capture of B throws
ALTER FUNCTION public.provenue_capture_event(jsonb, text, jsonb) RENAME TO provenue_capture_event_real;
CREATE FUNCTION public.provenue_capture_event(p_body jsonb, p_pid text, p_game jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  IF p_pid = '9000002' THEN RAISE EXCEPTION 'a parse fault'; END IF;
  RETURN public.provenue_capture_event_real(p_body, p_pid, p_game);
END $$;
INSERT INTO net._http_response (id, status_code, content, headers)
SELECT p.request_id, 200, '{"listings":[{"section":"101","row":"A","quantity":2,"ticketPrice":20,"fee":3,"totalPrice":23,"seats":"1,2","sellableQuantities":"1,2","ticketType":"Regular Ticket"}]}',
       '{"Tickets-Captures-Remaining":"990"}'
  FROM public.provenue_watch_poll p;
\echo '   the tick carries on: A settles ok, B is a settle_error, and the run is published'
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT pid, status_code, outcome, error, listings FROM public.provenue_watch_poll ORDER BY pid;
SELECT event_id, listing_count FROM public.v_primary_poll_events_feed WHERE source = 'provenue';
\echo '   B was billed: the budget counts it'
SELECT (public.provenue_watch_budget())->'billed_today' AS billed_today;

\echo '== 3. past retry_after and A''s band, A is read again; B waits the sold-out band, not retry_after'
UPDATE public.provenue_watch_poll SET fired_at = fired_at - interval '2 hours', checked_at = checked_at - interval '2 hours';
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '1 minute' WHERE source = 'provenue';
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT pid FROM public.provenue_watch_poll WHERE checked_at IS NULL;
\echo '   a day on, B is read again'
UPDATE public.provenue_watch_poll SET fired_at = fired_at - interval '1 day', checked_at = checked_at - interval '1 day' WHERE pid = '9000002';
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT pid FROM public.provenue_watch_poll WHERE checked_at IS NULL ORDER BY pid;
