-- Mig 20261128080000: the SeatGeek primary watch. The catalogue search finds the partner team's home games (and not
-- its away games or parking); a capture keeps the primary listings only; the event's totals are the primary seats'.
\pset footer off
INSERT INTO public.sg_events_canonical VALUES (18412995, 'Los Angeles Lakers at New Orleans Pelicans', 3600001);
UPDATE public.sgp_watch_team SET enabled = (team = 'New Orleans Pelicans');
SELECT enabled, discover_enabled, daily_cap FROM public.sgp_watch_config;

\echo '== 1. disabled for captures, the search is on: one search fires for the Pelicans (free), no capture'
SELECT public.sgp_watch_tick();
SELECT id, url, params->>'query' AS query, params->>'page' AS page, params->>'pageSize' AS page_size, headers ? 'x-api-key' AS keyed FROM net.sent ORDER BY id;

\echo '== 2. the search answers: the home game is kept; the away game, the parking event and another team are not'
INSERT INTO net._http_response (id, status_code, content)
SELECT q.request_id, 200, $j${"page":1,"hasMore":false,"events":[
  {"id":"T1","name":"Los Angeles Lakers at New Orleans Pelicans","eventDateUtc":"2099-12-03T01:00:00.000Z","eventDateLocal":"2099-12-02T19:00:00-06:00",
   "venue":{"name":"Smoothie King Center","city":"New Orleans","state":"LA","timezone":"America/Chicago"},
   "performers":[{"performerId":"2116","name":"New Orleans Pelicans","master":true},{"performerId":"2110","name":"Los Angeles Lakers","master":false}],
   "sources":[{"marketplace":"stubhub","eventId":"1","url":"https://www.stubhub.com/x"},
              {"marketplace":"seatgeek","eventId":"18412995","url":"https://seatgeek.com/new-orleans-pelicans-tickets/12-2-2099-new-orleans-louisiana-smoothie-king-center/nba/18412995"}]},
  {"id":"T2","name":"New Orleans Pelicans at Portland Trail Blazers","eventDateUtc":"2099-11-29T23:00:00.000Z","eventDateLocal":"2099-11-29T15:00:00-08:00",
   "venue":{"name":"Moda Center","city":"Portland","state":"OR","timezone":"America/Los_Angeles"},
   "performers":[{"name":"Portland Trail Blazers","master":true},{"name":"New Orleans Pelicans","master":false}],
   "sources":[{"marketplace":"seatgeek","eventId":"18496372","url":"https://seatgeek.com/x/18496372"}]},
  {"id":"T3","name":"Los Angeles Lakers at New Orleans Pelicans Parking","eventDateUtc":"2099-12-03T01:01:00.000Z","eventDateLocal":"2099-12-02T19:01:00-06:00",
   "venue":{"name":"Smoothie King Center Parking"},
   "performers":[{"name":"New Orleans Pelicans","master":true}],
   "sources":[{"marketplace":"seatgeek","eventId":"18414512","url":"https://seatgeek.com/x/parking/18414512"}]},
  {"id":"T4","name":"HIFK - Pelicans","eventDateUtc":"2099-12-16T16:30:00.000Z","venue":{"name":"Helsinki Ice Hall"},
   "performers":[{"name":"HIFK","master":true}],"sources":[]}
]}$j$
  FROM public.sgp_watch_search q WHERE q.checked_at IS NULL;
SELECT public.sgp_watch_tick();
SELECT team, page, outcome, events, home_games, has_more, masters FROM public.sgp_watch_search ORDER BY id;
SELECT sg_event_id, team, name, event_local, venue_name, url FROM public.sgp_watch_game;
SELECT sg_event_id, team, tevo_event_id FROM public.v_sgp_watch_games;

\echo '== 3. enabled: the game is captured through the SeatGeek reader'
UPDATE public.sgp_watch_config SET enabled = true;
SELECT public.sgp_watch_tick() - 'captures_remaining';
SELECT url, params->>'url' AS page FROM net.sent WHERE url LIKE '%capture%';

\echo '== 4. the capture holds primary and resale: only the primary listings are stored; totals are theirs'
INSERT INTO net._http_response (id, status_code, content, headers)
SELECT p.request_id, 200, $j${"source":"seatgeek","eventId":"18412995","eventName":"Los Angeles Lakers at New Orleans Pelicans","note":"",
  "eventDateLocal":"2099-12-02T19:00:00-06:00","eventDateUtc":"2099-12-03T01:00:00Z","venueName":"Smoothie King Center","venueCity":"New Orleans","venueState":"LA",
  "venueTimezone":"America/Chicago","stats":{"ticketCount":3442,"getInPrice":27,"maxPrice":3690},
  "listings":[
    {"listingId":"l_A","inventoryType":"primary","section":"101","row":"5","quantity":10,"ticketPrice":50,"fee":0,"totalPrice":50,"seats":"1,2,3,4,5,6,7,8,9,10","sellableQuantities":"1,2,3,4,5,6,7,8,10","ticketType":"","group":"","listingNotes":"","dealScore":"7"},
    {"listingId":"l_B","inventoryType":"primary","section":"301","row":"12","quantity":2,"ticketPrice":35,"fee":0,"totalPrice":35,"seats":"7,8","sellableQuantities":"2","ticketType":"","group":"","listingNotes":"","dealScore":"9"},
    {"listingId":"eeacK","inventoryType":"resale","section":"326","row":"7","quantity":2,"ticketPrice":19,"fee":8,"totalPrice":27,"seats":"9,10","sellableQuantities":"2","ticketType":"","group":"","listingNotes":"","dealScore":"9"}
  ]}$j$, '{"Tickets-Captures-Remaining":"950"}'
  FROM public.sgp_watch_poll p WHERE p.checked_at IS NULL;
SELECT public.sgp_watch_tick() - 'captures_remaining';
SELECT sg_event_id, outcome, listings, tickets, resale_listings, captures_remaining FROM public.sgp_watch_poll;
SELECT source, source_event_id, name, total_available, price_min, price_max, tevo_event_id, tevo_match_method, poll_interval, cadence_pinned
  FROM public.primary_poll_event WHERE source = 'seatgeek_primary';
SELECT listing_id, section, seat_row, quantity, max_per_order, all_in_price FROM public.primary_poll_listing WHERE source = 'seatgeek_primary' ORDER BY listing_id COLLATE "C";
SELECT event_id, name, listings_available FROM public.v_primary_poll_events_feed WHERE source = 'seatgeek_primary';

\echo '== 5. a team cap, set by hand, reaches the event when no block shows one'
UPDATE public.sgp_watch_config SET team_order_max = '{"New Orleans Pelicans": 8}';
SELECT public.sgp_capture_event('{"listings":[{"inventoryType":"primary","section":"1","row":"1","quantity":2,"ticketPrice":5,"fee":0,"totalPrice":5,"seats":"1,2","sellableQuantities":"1,2"}]}',
                                '18412995', public.sgp_watch_game_row('18412995'))->'order_max' AS order_max;

\echo '== 6. the budget'
SELECT public.sgp_watch_budget() - 'response_p50_s' - 'response_p90_s' - 'per_hour_at_in_flight';

\echo '== 7. the cron'
SELECT jobname, schedule, command FROM cron.job WHERE jobname LIKE 'sgp%';
