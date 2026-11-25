-- The AXS watch withholds seats that cannot be transferred and seats with a limited or side view (mig 20261124233030):
-- what the parse leaves out, what it marks obstructed, and the correction of the rows already stored.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the parse: a non-transferable offer is left out; a limited, side, partial or obstructed view is marked, in whichever label says so; an unobstructed one is not'
SELECT x.l->>'section' AS note_case, x.l->>'market' AS market, x.l->>'qty' AS qty, coalesce((x.l->>'obstructed')::boolean, false) AS obstructed
  FROM jsonb_array_elements(public.axs_watch_parse($j${"listings": [
    {"kind": "primary", "section": "01 plain", "row": "A", "seats": ["1", "2"], "quantity": 2, "seat_type": "STANDARD", "status": "Available", "offer_id": "1", "offer_name": "Show", "price_level": "P1", "pricing": {"face": 50, "all_in": 60}},
    {"kind": "primary", "section": "02 offer says non transferable", "row": "2", "seats": ["1", "2"], "quantity": 2, "seat_type": "STANDARD", "status": "Available", "offer_id": "2", "offer_name": "Show - Standard Rows 2 to 4 Non Transferable", "price_level": "P1", "pricing": {"face": 110, "all_in": 130}},
    {"kind": "primary", "section": "03 offer says non-transferable", "row": "3", "seats": ["5"], "quantity": 1, "seat_type": "STANDARD", "status": "Available", "offer_id": "3", "offer_name": "Show - Non-Transferable Best Available", "price_level": "P1", "pricing": {"face": 110, "all_in": 130}},
    {"kind": "resale", "section": "04 seller says not transferable", "row": "B", "seats": ["3"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "4", "price_level": "P2", "seller_notes": "Tickets are not transferable, will meet at gate", "pricing": {"face": 80, "all_in": 99}},
    {"kind": "resale", "section": "05 price code limited view", "row": "C", "seats": ["1", "2"], "quantity": 2, "seat_type": "FLASHSEATS", "offer_id": "5", "price_level": "PL6", "price_code": "Limited View", "pricing": {"face": 40, "all_in": 52}},
    {"kind": "resale", "section": "06 price code side view", "row": "D", "seats": ["4"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "6", "price_level": "P4 - UPPER LEVEL", "price_code": "Adult SIDE VIEW", "pricing": {"face": 70, "all_in": 88}},
    {"kind": "resale", "section": "07 price level limited view", "row": "E", "seats": ["7"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "7", "price_level": "Lower - Limited view", "pricing": {"face": 95, "all_in": 119}},
    {"kind": "primary", "section": "08 offer obstructed view", "row": "F", "seats": ["1"], "quantity": 1, "seat_type": "STANDARD", "status": "Available", "offer_id": "8", "offer_name": "Show - Obstructed View", "price_level": "P5", "pricing": {"face": 30, "all_in": 38}},
    {"kind": "primary", "section": "09 status partial view", "row": "G", "seats": ["1"], "quantity": 1, "seat_type": "STANDARD", "status": "OPEN - Partial View", "offer_id": "9", "offer_name": "Show", "price_level": "P5", "pricing": {"face": 30, "all_in": 38}},
    {"kind": "resale", "section": "10 seller says obstruction", "row": "H", "seats": ["2"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "10", "price_level": "P2", "seller_notes": "Small obstruction from the rail", "pricing": {"face": 60, "all_in": 75}},
    {"kind": "resale", "section": "11 seller says unobstructed", "row": "I", "seats": ["2"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "11", "price_level": "P2", "seller_notes": "Front row center. Unobstructed view of the ice.", "pricing": {"face": 60, "all_in": 75}},
    {"kind": "resale", "section": "12 seller says great view, behind goal", "row": "J", "seats": ["2"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "12", "price_level": "P2", "price_code": "Aisle", "seller_notes": "Aisle Seats Behind Home Goal, great view of the bench", "pricing": {"face": 60, "all_in": 75}},
    {"kind": "primary", "section": "13 vip package", "row": "K", "seats": ["1", "2"], "quantity": 2, "seat_type": "STANDARD", "status": "Available", "offer_id": "13", "offer_name": "Show - Early Entry VIP Package", "price_level": "VIP1", "pricing": {"face": 300, "all_in": 350}},
    {"kind": "primary", "section": "14 axs premium", "row": "3", "seats": ["1", "2"], "quantity": 2, "seat_type": "PREMIUM", "status": "AXS Premium POSTED AXS", "offer_id": "14", "offer_name": "Show AXS Premium Admissions", "price_level": "P3", "pricing": {"face": 134.5, "all_in": 158.7}},
    {"kind": "resale", "section": "15 resale in a premium section", "row": "9", "seats": ["1", "2"], "quantity": 2, "seat_type": "FLASHSEATS", "offer_id": "15", "price_level": "Premier", "pricing": {"face": 366, "all_in": 459.33}}
  ]}$j$::jsonb)->'listings') x(l)
 ORDER BY 1;

\echo '--- B. the rows already stored: an event''s last good read is parsed again; the non-transferable listing is removed, the limited-view one marked, the counts recomputed'
-- the stored state as the parser before this migration left it: three listings, none obstructed
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events) VALUES ('axs', 'r1', now(), 1)
  ON CONFLICT (source) DO UPDATE SET current_run = 'r1';
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, venue_name, ticket_url, announced_at, poll_status, poll_ok_at, last_run, next_poll_at, order_max, listing_count, listed_quantity)
VALUES ('axs', '501', 'Show At The Rocks', current_date + 30, 'Red Rocks Amphitheatre', 'https://www.axs.com/events/501/show-tickets', now(), 'ok', now(), 'r1', now() + interval '1 hour', 8, 3, 5),
       ('axs', '502', 'Show With No Response Left', current_date + 30, 'Red Rocks Amphitheatre', 'https://www.axs.com/events/502/show-tickets', now(), 'ok', now(), 'r1', now() + interval '1 hour', 8, 1, 2);
INSERT INTO net._http_response (id, status_code, content) VALUES
  (901, 200, $j${"quota_remaining": 5000, "body": {"status": "ok", "listings": [
     {"kind": "primary", "section": "1", "row": "10", "seats": ["1", "2"], "quantity": 2, "seat_type": "STANDARD", "status": "Available", "offer_id": "1", "offer_name": "Show", "price_level": "P1", "pricing": {"face": 50, "all_in": 60}},
     {"kind": "primary", "section": "1", "row": "2", "seats": ["1", "2"], "quantity": 2, "seat_type": "STANDARD", "status": "Available", "offer_id": "2", "offer_name": "Show - Rows 2 to 4 Non Transferable", "price_level": "P1", "pricing": {"face": 110, "all_in": 130}},
     {"kind": "resale", "section": "2", "row": "C", "seats": ["4"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "5", "price_level": "PL6", "price_code": "Limited View", "pricing": {"face": 40, "all_in": 52}}]}}$j$);
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, listings) VALUES
  (901, '501', now() - interval '1 minute', now(), 200, 'ok', 3),
  (902, '502', now() - interval '1 minute', now(), 200, 'ok', 1);      -- its response is gone from net._http_response
INSERT INTO public.primary_poll_listing (source, source_event_id, listing_id, market, section, seat_row, seats, quantity, price, all_in_price, obstructed)
SELECT 'axs', '501', abs(hashtextextended(concat_ws('|', v.offer, v.market, v.section, v.seat_row, v.ticket_type, v.seats::text, v.price::text), 0))::text,
       v.market, v.section, v.seat_row, v.seats, jsonb_array_length(v.seats), v.price, v.all_in, false
  FROM (VALUES ('1', 'primary', '1', '10', 'STANDARD', '["1", "2"]'::jsonb, 50::numeric, 60::numeric),
               ('2', 'primary', '1', '2',  'STANDARD', '["1", "2"]'::jsonb, 110::numeric, 130::numeric),
               ('5', 'resale',  '2', 'C',  'FLASHSEATS', '["4"]'::jsonb, 40::numeric, 52::numeric)) v(offer, market, section, seat_row, ticket_type, seats, price, all_in);
INSERT INTO public.primary_poll_listing (source, source_event_id, listing_id, market, section, seat_row, seats, quantity, price, all_in_price, obstructed)
VALUES ('axs', '502', 'kept-until-next-read', 'primary', '1', '3', '["1", "2"]'::jsonb, 2, 110, 130, false);
\i ../../../../supabase/migrations/20261124233030_axs_watch_withheld_notes.sql
SELECT source_event_id AS event, section, seat_row AS "row", market, quantity AS qty, obstructed FROM public.primary_poll_listing WHERE source = 'axs' AND source_event_id IN ('501', '502') ORDER BY 1, 2, 3;
SELECT source_event_id AS event, listing_count, listed_quantity, total_available, median_price, price_min, price_max FROM public.primary_poll_event WHERE source = 'axs' AND source_event_id IN ('501', '502') ORDER BY 1;
SELECT event_id, section, seat_row AS "row", quantity AS qty FROM public.v_primary_poll_listings_feed WHERE source = 'axs' AND event_id IN ('501', '502') ORDER BY 1, 2, 3;
