-- The ProVenue watch end to end: which games it reads, what one capture becomes, how each kind of failure is
-- treated, and what holds it back.
\pset footer off
-- the schedule: A and B in the horizon and on sale; C past the horizon; D not on sale; E a minor-league game;
-- F removed; G Ticketmaster; H already started
INSERT INTO public.mlb_ticket_game (mlb_game_id, sport_id, game_type, game_date, game_time_utc, game_time_local, home_abbrev, away_abbrev,
       home_name, away_name, venue_name, venue_city, ticket_url, primary_seller, primary_event_id, on_sale_start, tevo_event_id, removed_at)
VALUES
 ('A', 1, 'R', (now() + interval '1 day')::date,   now() + interval '1 day',   '2027-03-30T18:45:00', 'WSH', 'NYM', 'Washington Nationals', 'New York Mets', 'Nationals Park', 'Washington',
  'https://mlb.tickets.com/?orgid=17&agency=MLB_MPV&pid=9813431', 'provenue', '9813431', '2026-10-29 14:17', 3483004, NULL),
 ('B', 1, 'R', (now() + interval '30 hours')::date, now() + interval '30 hours', '2027-03-31T19:05:00', 'PHI', 'TB', 'Philadelphia Phillies', 'Tampa Bay Rays', 'Citizens Bank Park', 'Philadelphia',
  'https://mlb.tickets.com/?orgid=21&agency=MLB_MPV&pid=9643120', 'provenue', '9643120', NULL, 3400001, NULL),
 ('C', 1, 'R', (now() + interval '5 days')::date,  now() + interval '5 days',  '2027-04-03T13:05:00', 'WSH', 'NYM', 'Washington Nationals', 'New York Mets', 'Nationals Park', 'Washington',
  'https://mlb.tickets.com/?orgid=17&agency=MLB_MPV&pid=9813440', 'provenue', '9813440', NULL, NULL, NULL),
 ('D', 1, 'R', (now() + interval '1 day')::date,   now() + interval '1 day',   '2027-03-30T19:10:00', 'MIN', 'KC', 'Minnesota Twins', 'Kansas City Royals', 'Target Field', 'Minneapolis',
  'https://mlb.tickets.com/?orgid=1&agency=MLB_MPV&pid=1000001', 'provenue', '1000001', (now() AT TIME ZONE 'America/New_York') + interval '3 days', NULL, NULL),
 ('E', 11, 'R', (now() + interval '1 day')::date,  now() + interval '1 day',   '2027-03-30T19:05:00', 'SYR', 'ROC', 'Syracuse Mets', 'Rochester Red Wings', 'NBT Bank Stadium', 'Syracuse',
  'https://mpv.tickets.com/?orgid=2&eventId=2000001', 'provenue', '2000001', NULL, NULL, NULL),
 ('F', 1, 'R', (now() + interval '1 day')::date,   now() + interval '1 day',   '2027-03-30T19:05:00', 'SF', 'LAD', 'San Francisco Giants', 'Los Angeles Dodgers', 'Oracle Park', 'San Francisco',
  'https://mlb.tickets.com/?orgid=3&agency=MLB_MPV&pid=3000001', 'provenue', '3000001', NULL, NULL, now() - interval '1 day'),
 ('G', 1, 'R', (now() + interval '1 day')::date,   now() + interval '1 day',   '2027-03-30T19:05:00', 'SEA', 'HOU', 'Seattle Mariners', 'Houston Astros', 'T-Mobile Park', 'Seattle',
  'https://www.ticketmaster.com/event/X', 'ticketmaster', 'X', NULL, NULL, NULL),
 ('H', 1, 'R', current_date, now() - interval '1 hour', '2027-03-29T19:05:00', 'PIT', 'CIN', 'Pittsburgh Pirates', 'Cincinnati Reds', 'PNC Park', 'Pittsburgh',
  'https://mlb.tickets.com/?orgid=4&agency=MLB_MPV&pid=4000001', 'provenue', '4000001', NULL, NULL, NULL);

\echo '== 1. disabled: the tick only settles'
SELECT public.provenue_watch_tick();
SELECT count(*) AS sent FROM net.sent;

\echo '== 2. enabled, two-day horizon: A and B fire (never read, soonest first), one GET each, key in the header, no venue map'
UPDATE public.provenue_watch_config SET enabled = true, horizon_days = 2, daily_cap = 1000, hourly_cap = 100;
SELECT pid FROM public.v_provenue_watch_games ORDER BY game_time_utc;
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT id, url, params, headers FROM net.sent ORDER BY id;
SELECT request_id, pid, mlb_game_id, checked_at IS NULL AS in_flight FROM public.provenue_watch_poll ORDER BY request_id;

\echo '== 3. A answers with a capture (shape of the Mets at Nationals sample), B with rate_limited'
INSERT INTO net._http_response (id, status_code, content, headers) VALUES
 (1, 200, $j${"source":"provenue","eventId":"9813431","eventName":"Mets at Nationals","venueName":"Nationals Park","venueCity":"Washington","venueState":"DC",
   "venueTimezone":"America/New_York","eventDateLocal":"2027-03-30T18:45:00.000-04:00","eventDateUtc":"2027-03-30T22:45:00+00:00","note":"",
   "stats":{"listingCount":5,"ticketCount":41,"getInPrice":11,"medianPrice":22,"avgPrice":50,"maxPrice":225},
   "listings":[
    {"listingId":"","inventoryType":"primary","section":"229","row":"N","quantity":7,"ticketPrice":9,"fee":2,"totalPrice":11,"ticketType":"Regular Ticket","sellableQuantities":"1,2,3,4,5,6,7","group":"Scoreboard Pavilion","seats":"15,16,17,18,19,20,21","listingNotes":"","dealScore":""},
    {"listingId":"","inventoryType":"primary","section":"229","row":"N","quantity":7,"ticketPrice":9,"fee":2,"totalPrice":11,"ticketType":"Regular Ticket","sellableQuantities":"1,2,3,4,5,6,7","group":"Scoreboard Pavilion","seats":"1,2,3,4,5,6,7","listingNotes":"","dealScore":""},
    {"listingId":"","inventoryType":"primary","section":"106","row":"S","quantity":1,"ticketPrice":19,"fee":3,"totalPrice":22,"ticketType":"Regular Ticket","sellableQuantities":"1","group":"Outfield Reserved","seats":"5","listingNotes":"Obstructed View - Foul Pole","dealScore":""},
    {"listingId":"","inventoryType":"primary","section":"304","row":"J","quantity":24,"ticketPrice":15,"fee":2,"totalPrice":17,"ticketType":"Regular Ticket","sellableQuantities":"1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24","group":"Gallery Reserved","seats":"10,9,8,7,6,5,4,3,2,1,18,17,16,15,14,13,12,11,19,20,21,22,23,24","listingNotes":"","dealScore":""},
    {"listingId":"","inventoryType":"primary","section":"DC119","row":"D","quantity":2,"ticketPrice":207,"fee":18,"totalPrice":225,"ticketType":"PNC Diamond Club (All-Inclusive Food & Beverage, Indoor Club Access)","sellableQuantities":"1,2","group":"PNC Diamond Club (All-Inclusive F&B)","seats":"5,6","listingNotes":"","dealScore":""}],
   "venueLayout":{"level":"none","sections":[]}}$j$, '{"Tickets-Captures-Remaining":"998"}'),
 (2, 429, '{"error":{"code":"rate_limited","message":"Too many captures in flight","outcome":"rejected","retryable":true}}', '{"Retry-After":"30"}');
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT pid, status_code, outcome, error, listings, tickets, captures_remaining FROM public.provenue_watch_poll ORDER BY request_id;
SELECT source, source_event_id, name, event_date, start_local_time, timezone, venue_state, total_available, price_min, price_max,
       poll_status, listing_count, tevo_event_id, tevo_match_method FROM public.primary_poll_event ORDER BY source_event_id;
SELECT listing_id, section, seat_row, seat_low, seat_high, quantity, max_per_order, jsonb_array_length(allowed_quantities) AS n_qty,
       price, fee, all_in_price, area, obstructed, general_admission, notes
  FROM public.primary_poll_listing WHERE source = 'provenue' ORDER BY listing_id COLLATE "C";
SELECT seats FROM public.primary_poll_listing WHERE source = 'provenue' AND section = '304';
\echo '   in the feed, joined to EVO through the schedule'
SELECT source, event_id, name, listings_available, listing_count, tevo_event_id, tevo_match_method FROM public.v_primary_poll_events_feed WHERE source = 'provenue';
SELECT listing_id, area, all_in_price FROM public.v_primary_poll_listings_feed WHERE source = 'provenue' ORDER BY all_in_price, listing_id COLLATE "C";

\echo '== 4. at once again: A read within the hour, B inside retry_after: nothing fires'
SELECT public.provenue_watch_tick() - 'captures_remaining';

\echo '== 5. an hour later both are due again; the hourly cap of 1 lets only the one never read successfully go'
UPDATE public.provenue_watch_poll SET fired_at = fired_at - interval '61 minutes', checked_at = checked_at - interval '61 minutes';
UPDATE public.provenue_watch_config SET hourly_cap = 1;
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT request_id, pid FROM public.provenue_watch_poll WHERE checked_at IS NULL;

\echo '== 6. B: event_not_found is a failed read of B (a capture would survive one); A: a quota_exceeded holds the watch'
INSERT INTO net._http_response (id, status_code, content) VALUES
 (3, 404, '{"error":{"code":"event_not_found","message":"No event at that URL","outcome":"failed","retryable":false}}');
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT source_event_id, poll_status, poll_error, failed_reads FROM public.primary_poll_event WHERE source = 'provenue' ORDER BY 1;
UPDATE public.provenue_watch_config SET hourly_cap = 100;
UPDATE public.provenue_watch_poll SET fired_at = fired_at - interval '61 minutes', checked_at = checked_at - interval '61 minutes' WHERE checked_at IS NOT NULL;
SELECT public.provenue_watch_tick() - 'captures_remaining';
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 429, '{"error":{"code":"quota_exceeded","message":"No captures left","outcome":"rejected","retryable":false}}'
  FROM public.provenue_watch_poll p WHERE p.checked_at IS NULL AND p.pid = '9813431';
INSERT INTO net._http_response (id, status_code, content)
SELECT p.request_id, 200, '{"eventId":"9643120","eventName":"Rays at Phillies","listings":[],"note":"Not yet on sale"}'
  FROM public.provenue_watch_poll p WHERE p.checked_at IS NULL AND p.pid = '9643120';
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT pid, status_code, outcome, error FROM public.provenue_watch_poll ORDER BY request_id;
\echo '   A keeps its capture: a quota error is ours, not the game''s'
SELECT source_event_id, poll_status, listing_count FROM public.primary_poll_event WHERE source = 'provenue' ORDER BY 1;

\echo '== 7. a request with no response by stale_after is lost and the game is retried; the balance at reserve holds the watch'
DELETE FROM public.provenue_watch_poll WHERE outcome = 'quota_exceeded';
UPDATE public.provenue_watch_poll SET fired_at = fired_at - interval '2 hours', checked_at = checked_at - interval '2 hours' WHERE checked_at IS NOT NULL;
SELECT public.provenue_watch_tick() - 'captures_remaining';
UPDATE public.provenue_watch_poll SET fired_at = now() - interval '6 minutes' WHERE checked_at IS NULL;
SELECT public.provenue_watch_tick() - 'captures_remaining';
SELECT pid, outcome FROM public.provenue_watch_poll WHERE outcome = 'lost' ORDER BY request_id;
UPDATE public.provenue_watch_poll SET captures_remaining = 20 WHERE outcome = 'ok';
UPDATE public.provenue_watch_poll SET fired_at = fired_at - interval '1 hour', checked_at = checked_at - interval '1 hour';
SELECT public.provenue_watch_tick();
\echo '== 8. the budget, readable'
SELECT public.provenue_watch_budget() - 'billed_today' - 'billed_last_hour' - 'quota_exceeded_at';
\echo '== 9. the cron'
SELECT jobname, schedule, command FROM cron.job WHERE jobname LIKE 'provenue%';
