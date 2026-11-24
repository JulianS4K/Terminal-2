-- A listing over its order limit is sent as several (mig 20261124230030): the limit, the cut at the gaps in the seat
-- numbers, the cut by the limit, no single seat left behind, general admission by count, and the switch.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the limit: the largest quantity the listing sells within the order cap; none where it sells only whole and over it'
SELECT c.label, public.primary_poll_limit(c.allowed, c.own, c.cap) AS order_limit
  FROM (VALUES (1, '7 seats sold as 1-5 or all 7, cap 6', '[1,2,3,4,5,7]'::jsonb, 6, 6),
               (2, 'sold only whole (8), cap 6',          '[8]'::jsonb, 6, 6),
               (3, 'no quantities given, cap 8',          NULL::jsonb, NULL::integer, 8),
               (4, 'no cap on the event, the listing says 4', NULL::jsonb, 4, NULL::integer),
               (5, 'pairs only, cap 8',                   '[2,4,6,8,10]'::jsonb, NULL::integer, 8),
               (6, 'nothing known',                       NULL::jsonb, NULL::integer, NULL::integer)) c(n, label, allowed, own, cap)
 ORDER BY c.n;

\echo '--- B. the pieces: cut at the gaps, then by the limit; a seat that would be left alone stays with the set before it'
SELECT c.label, string_agg(x.quantity || coalesce(' [' || x.seat_low || '-' || x.seat_high || ']', ''), ' + ' ORDER BY x.part) AS sent_as
  FROM (VALUES (1, '5 together, limit 4',   '["1","2","3","4","5"]'::jsonb, 5, 4),
               (2, '7 together, limit 4',   '["1","2","3","4","5","6","7"]'::jsonb, 7, 4),
               (3, '8 together, limit 4',   '["1","2","3","4","5","6","7","8"]'::jsonb, 8, 4),
               (4, '9 together, limit 4',   '["1","2","3","4","5","6","7","8","9"]'::jsonb, 9, 4),
               (5, '3 together, limit 2',   '["1","2","3"]'::jsonb, 3, 2),
               (6, '3 together, limit 1',   '["1","2","3"]'::jsonb, 3, 1),
               (7, '1-4 and 6, limit 4',    '["1","2","3","4","6"]'::jsonb, 5, 4),
               (8, '1-5 and 9-10, limit 4', '["1","2","3","4","5","9","10"]'::jsonb, 7, 4),
               (9, 'unordered 9,7,8,1,2, limit 2', '["9","7","8","1","2"]'::jsonb, 5, 2),
               (10, 'general admission 11, limit 10', NULL::jsonb, 11, 10),
               (11, 'seats not numbers (A-E), limit 4', '["A","B","C","D","E"]'::jsonb, 5, 4),
               (12, 'fewer seat numbers than tickets, limit 2', '["1","2"]'::jsonb, 5, 2)) c(n, label, seats, qty, lim)
 CROSS JOIN LATERAL public.primary_poll_pieces(c.seats, c.qty, c.lim) x
 GROUP BY c.n, c.label ORDER BY c.n;
SELECT count(*) AS pieces, sum(quantity) AS tickets, min(quantity) AS smallest, max(quantity) AS largest
  FROM public.primary_poll_pieces(NULL, 13014, 10);

\echo '--- C. a read is stored: the listings keep the box office''s blocks, with their limit'
SELECT public.primary_poll_ingest('timberwolves', jsonb_build_array(jsonb_build_object(
  'id', 'G1', 'name', 'Home Team vs. Visitors', 'local_date', to_char(current_date + 30, 'YYYY-MM-DD'), 'order_min', 1, 'order_max', 6, 'ok', true,
  'listings', jsonb_build_array(
    jsonb_build_object('id', 'under', 'market', 'primary', 'section', '101', 'row', 'A', 'seat_low', '1', 'seat_high', '4', 'seats', '["1","2","3","4"]'::jsonb, 'qty', 4, 'allowed_quantities', '[1,2,4]'::jsonb, 'max_per_order', 4, 'price', 50),
    jsonb_build_object('id', 'seven', 'market', 'primary', 'section', '102', 'row', 'B', 'seat_low', '3', 'seat_high', '9', 'seats', '["3","4","5","6","7","8","9"]'::jsonb, 'qty', 7, 'allowed_quantities', '[1,2,3,4,5,7]'::jsonb, 'max_per_order', 5, 'price', 60),
    jsonb_build_object('id', 'thirteen', 'market', 'primary', 'section', '103', 'row', 'C', 'seat_low', '1', 'seat_high', '13', 'seats', (SELECT jsonb_agg(v::text) FROM generate_series(1, 13) v), 'qty', 13, 'allowed_quantities', '[1,2,3,4,5,6]'::jsonb, 'max_per_order', 6, 'price', 70),
    jsonb_build_object('id', 'gaps', 'market', 'primary', 'section', '104', 'row', 'D', 'seat_low', '1', 'seat_high', '21', 'seats', '["1","2","3","4","5","6","7","8","20","21"]'::jsonb, 'qty', 10, 'allowed_quantities', '[1,2,3,4,5,6]'::jsonb, 'max_per_order', 6, 'price', 80),
    jsonb_build_object('id', 'oneover', 'market', 'primary', 'section', '105', 'row', 'E', 'seat_low', '1', 'seat_high', '7', 'seats', '["1","2","3","4","5","6","7"]'::jsonb, 'qty', 7, 'allowed_quantities', '[1,2,3,4,5,6]'::jsonb, 'max_per_order', 6, 'price', 90),
    jsonb_build_object('id', 'whole', 'market', 'resale', 'section', '106', 'row', 'F', 'seat_low', '1', 'seat_high', '8', 'seats', '["1","2","3","4","5","6","7","8"]'::jsonb, 'qty', 8, 'allowed_quantities', '[8]'::jsonb, 'price', 100),
    jsonb_build_object('id', 'ga', 'market', 'primary', 'section', 'GA', 'qty', 14, 'allowed_quantities', '[1,2,3,4,5,6]'::jsonb, 'max_per_order', 6, 'ga', true, 'price', 30),
    jsonb_build_object('id', 'blocked', 'market', 'primary', 'section', '107', 'row', 'G', 'seats', '["1","2","3","4","5","6","7","8","9"]'::jsonb, 'qty', 9, 'allowed_quantities', '[1,2,3,4,5,6]'::jsonb, 'max_per_order', 6, 'obstructed', true, 'price', 20))))) AS stored;
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events) VALUES ('timberwolves', 'r1', now(), 1)
  ON CONFLICT (source) DO UPDATE SET current_run = 'r1';
UPDATE public.primary_poll_event SET last_run = 'r1' WHERE source = 'timberwolves';
SELECT listing_id, quantity, max_per_order, order_limit, obstructed FROM public.primary_poll_listing WHERE source = 'timberwolves' ORDER BY listing_id;
SELECT listing_count, listed_quantity FROM public.primary_poll_event WHERE source = 'timberwolves';

\echo '--- D. the feed sends the pieces in place of a listing over its limit; the obstructed one is never sent'
SELECT listing_id, section, seat_low, seat_high, seats, quantity, allowed_quantities, max_per_order, split_of, split_part AS part, split_parts AS parts
  FROM public.v_primary_poll_listings_feed WHERE source = 'timberwolves' ORDER BY section, split_part;
SELECT count(*) AS listings_sent, sum(quantity) AS tickets_sent,
       (SELECT sum(l.quantity) FROM public.primary_poll_listing l WHERE l.source = 'timberwolves' AND NOT l.obstructed) AS tickets_stored
  FROM public.v_primary_poll_listings_feed WHERE source = 'timberwolves';

\echo '--- E. the next read replaces the pieces with the listings; a failed read removes both'
SELECT public.primary_poll_ingest('timberwolves', jsonb_build_array(jsonb_build_object(
  'id', 'G1', 'name', 'Home Team vs. Visitors', 'local_date', to_char(current_date + 30, 'YYYY-MM-DD'), 'order_min', 1, 'order_max', 6, 'ok', true,
  'listings', jsonb_build_array(
    jsonb_build_object('id', 'thirteen', 'market', 'primary', 'section', '103', 'row', 'C', 'seats', (SELECT jsonb_agg(v::text) FROM generate_series(1, 9) v), 'qty', 9, 'allowed_quantities', '[1,2,3,4,5,6]'::jsonb, 'max_per_order', 6, 'price', 70))))) AS stored;
SELECT listing_id, seat_low, seat_high, quantity, max_per_order FROM public.v_primary_poll_listings_feed WHERE source = 'timberwolves' ORDER BY listing_id;
SELECT (SELECT count(*) FROM public.primary_poll_listing_piece) AS pieces_stored;
SELECT public.primary_poll_ingest('timberwolves', jsonb_build_array(jsonb_build_object('id', 'G1', 'name', 'Home Team vs. Visitors', 'ok', false, 'error', 'no answer'))) AS stored;
SELECT (SELECT count(*) FROM public.primary_poll_listing WHERE source = 'timberwolves') AS listings_stored,
       (SELECT count(*) FROM public.primary_poll_listing_piece) AS pieces_stored;

\echo '--- F. the switch: off, the blocks go out as the box office gave them'
SELECT public.primary_poll_ingest('timberwolves', jsonb_build_array(jsonb_build_object(
  'id', 'G1', 'name', 'Home Team vs. Visitors', 'local_date', to_char(current_date + 30, 'YYYY-MM-DD'), 'order_min', 1, 'order_max', 6, 'ok', true,
  'listings', jsonb_build_array(
    jsonb_build_object('id', 'thirteen', 'market', 'primary', 'section', '103', 'row', 'C', 'seat_low', '1', 'seat_high', '13', 'seats', (SELECT jsonb_agg(v::text) FROM generate_series(1, 13) v), 'qty', 13, 'allowed_quantities', '[1,2,3,4,5,6]'::jsonb, 'max_per_order', 6, 'price', 70))))) AS stored;
UPDATE public.primary_poll_config SET split_over_limit = false;
SELECT listing_id, seat_low, seat_high, quantity, max_per_order, split_of FROM public.v_primary_poll_listings_feed WHERE source = 'timberwolves';
UPDATE public.primary_poll_config SET split_over_limit = true;
SELECT listing_id, seat_low, seat_high, quantity, max_per_order, split_of FROM public.v_primary_poll_listings_feed WHERE source = 'timberwolves' ORDER BY split_part;

\echo '--- G. service only'
SET ROLE anon;
SELECT public.primary_poll_split_event('timberwolves', 'G1');
SELECT count(*) FROM public.primary_poll_listing_piece;
RESET ROLE;
SELECT has_function_privilege('service_role', 'public.primary_poll_split_event(text, text)', 'EXECUTE') AS service_can_split,
       has_table_privilege('service_role', 'public.primary_poll_listing_piece', 'SELECT') AS service_can_read,
       has_table_privilege('anon', 'public.primary_poll_listing_piece', 'SELECT') AS anon_can_read;
