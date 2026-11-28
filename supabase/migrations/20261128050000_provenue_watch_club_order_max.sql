-- Migration 20261128050000 · level:data-collection · lane:a1 (ProVenue watch) · writes:provenue_watch_config(+club_order_max),provenue_watch_game()(replace),provenue_capture_event()(replace) · reads:provenue_watch_config
--
-- A club's order cap, set by hand where the box office states it, for the games whose capture does not show it.
-- Operator 2026-11-28, with the Phillies' checkout ("ERROR: You cannot select more than 8 seats in Field (115-116,
-- 131-132) rows 11-26. ERROR: You can only select 8 seats as Regular Ticket."): "phillies, hard code for all games
-- unless reader says otherwise".
--
-- provenue_watch_config.club_order_max maps a club (mlb_ticket_game.home_abbrev) to its cap: {"PHI": 8}. The
-- schedule row (provenue_watch_game) carries it to the capture, and the event's order_max is the cap a capped block
-- shows (mig 20261128030000) or else the club's. So a Phillies game whose blocks all sell whole still goes to the
-- CRM with order_max 8; one whose capture shows another cap sends that. primary_poll_limit takes the event's
-- order_max first, so a Phillies block over 8 is sent as pieces of 8 (mig 20261124230030).
-- Another club: UPDATE provenue_watch_config SET club_order_max = club_order_max || '{"XXX": n}'.

BEGIN;

ALTER TABLE public.provenue_watch_config ADD COLUMN IF NOT EXISTS club_order_max jsonb NOT NULL DEFAULT '{}'::jsonb;
UPDATE public.provenue_watch_config SET club_order_max = club_order_max || '{"PHI": 8}'::jsonb;

CREATE OR REPLACE FUNCTION public.provenue_watch_game(p_pid text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_strip_nulls(jsonb_build_object(
           'name', g.away_name || ' at ' || g.home_name,
           'local_date', g.game_date::text,
           'local_time', substring(g.game_time_local::text FROM 'T?(\d{2}:\d{2})'),
           'start_utc', g.game_time_utc,
           'venue', g.venue_name, 'city', g.venue_city, 'url', g.ticket_url,
           'tevo_event_id', g.tevo_event_id, 'mlb_game_id', g.mlb_game_id,
           'order_max', (SELECT c.club_order_max->>g.home_abbrev FROM public.provenue_watch_config c)))
    FROM public.mlb_ticket_game g
   WHERE g.primary_event_id = p_pid AND g.primary_seller = 'provenue'
   ORDER BY g.removed_at NULLS FIRST, g.game_time_utc
   LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.provenue_capture_event(p_body jsonb, p_pid text, p_game jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH l AS (
    SELECT x AS j,
           -- seats sorted: numbers numerically, then anything else ('1C', a companion seat) as text. The cast sits in
           -- a per-row CASE: an aggregate inside a CASE is computed for every branch, so the old
           -- CASE WHEN bool_and(...) THEN array_agg(s ORDER BY s::int) cast '1C' anyway and failed the whole tick
           (SELECT array_agg(s ORDER BY CASE WHEN s ~ '^[0-9]{1,9}$' THEN s::int END, s)
              FROM unnest(string_to_array(regexp_replace(coalesce(x->>'seats', ''), '\s', '', 'g'), ',')) s
             WHERE s <> '') AS seats,
           (SELECT array_agg(q::int ORDER BY q::int)
              FROM unnest(string_to_array(regexp_replace(coalesce(x->>'sellableQuantities', ''), '\s', '', 'g'), ',')) q
             WHERE q ~ '^[0-9]+$') AS qtys
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'listings') = 'array' THEN p_body->'listings' ELSE '[]'::jsonb END) x
  ), lim AS (
    -- the order limit, as the AXS watch sends it (event order_min / order_max): ProVenue prints none, but a club's
    -- cap shows wherever a block holds more seats than can be bought at once (sellableQuantities stops short of the
    -- quantity: the Marlins 9, the Padres 8, the Pirates 14, the Rays 19, the Giants 20). Only then is the most
    -- any block sells the cap; where every block sells whole (the Nationals, up to 33) the cap is unknown: null.
    SELECT min(l.qtys[1]) AS omin,
           CASE WHEN bool_or(l.qtys[array_length(l.qtys, 1)] < (l.j->>'quantity')::int)
                THEN max(l.qtys[array_length(l.qtys, 1)]) END AS omax
      FROM l
     WHERE coalesce(l.j->>'section', '') <> '' AND l.j->>'quantity' ~ '^[0-9]+$'
  ), r AS (
    SELECT concat_ws('|', l.j->>'section', l.j->>'row',
                     coalesce(l.seats[1] || '-' || l.seats[array_length(l.seats, 1)], 'q' || (l.j->>'quantity')),
                     coalesce(nullif(l.j->>'ticketType', ''), 'Regular Ticket')) AS base,
           left(md5(l.j::text), 6) AS tag,
           jsonb_strip_nulls(jsonb_build_object(
             'market', 'primary',
             'section', nullif(l.j->>'section', ''),
             'row', nullif(l.j->>'row', ''),
             'seat_low', l.seats[1],
             'seat_high', l.seats[array_length(l.seats, 1)],
             'seats', to_jsonb(l.seats),
             'qty', CASE WHEN l.j->>'quantity' ~ '^[0-9]+$' THEN (l.j->>'quantity')::int END,
             'allowed_quantities', to_jsonb(l.qtys),
             'max_per_order', l.qtys[array_length(l.qtys, 1)],
             'price', CASE WHEN jsonb_typeof(l.j->'ticketPrice') = 'number' THEN (l.j->>'ticketPrice')::numeric END,
             'fee', CASE WHEN jsonb_typeof(l.j->'fee') = 'number' THEN (l.j->>'fee')::numeric END,
             'all_in', CASE WHEN jsonb_typeof(l.j->'totalPrice') = 'number' THEN (l.j->>'totalPrice')::numeric END,
             'area', nullif(l.j->>'group', ''),
             'ticket_type', nullif(l.j->>'ticketType', ''),
             'obstructed', coalesce(l.j->>'listingNotes', '') ~* '(obstruct|sightline|foul ?pole|limited view|partial view)',
             'ga', CASE WHEN l.j->>'section' ~* '^(STAND|SRO|GA)' OR l.j->>'row' ~* '^SRO'
                          OR coalesce(l.j->>'listingNotes', '') ~* 'standing room' THEN true END,
             'ada', CASE WHEN coalesce(l.j->>'listingNotes', '') || ' ' || coalesce(l.j->>'ticketType', '')
                              ~* '(wheelchair|\mada\M|accessible|companion)' THEN true END,
             'notes', nullif(l.j->>'listingNotes', '')
           )) AS row
      FROM l
     WHERE coalesce(l.j->>'section', '') <> ''
  ), u AS (
    -- the id is section|row|first-last seat|ticket type. Two blocks of one capture can share it (the first PHI and
    -- STL reads lost 12 and 7 listings that way: the second overwrote the first in the store); then each of them
    -- carries a tag of its own content after a '~', and every other listing keeps its id. A block repeated word
    -- for word (the same tag) is not a second block: it keeps its id and is kept once.
    SELECT DISTINCT ON (id) id, row
      FROM (SELECT CASE WHEN min(r.tag) OVER (PARTITION BY r.base) <> max(r.tag) OVER (PARTITION BY r.base) THEN r.base || '~' || r.tag ELSE r.base END AS id, r.row
              FROM r) x
     ORDER BY id
  )
  SELECT jsonb_strip_nulls(jsonb_build_object(
           'id', p_pid,
           'name', coalesce(nullif(p_body->>'eventName', ''), p_game->>'name'),
           'local_date', coalesce(substring(p_body->>'eventDateLocal' FROM '^\d{4}-\d{2}-\d{2}'), p_game->>'local_date'),
           'local_time', coalesce(substring(p_body->>'eventDateLocal' FROM 'T(\d{2}:\d{2})'), p_game->>'local_time'),
           'start_utc', coalesce(nullif(p_body->>'eventDateUtc', ''), p_game->>'start_utc'),
           'timezone', coalesce(nullif(p_body->>'venueTimezone', ''), p_game->>'timezone'),
           'venue', coalesce(nullif(p_body->>'venueName', ''), p_game->>'venue'),
           'city', coalesce(nullif(p_body->>'venueCity', ''), p_game->>'city'),
           'state', nullif(p_body->>'venueState', ''),
           'url', p_game->>'url',
           'total_available', CASE WHEN jsonb_typeof(p_body#>'{stats,ticketCount}') = 'number' THEN (p_body#>>'{stats,ticketCount}')::int END,
           'price_min', CASE WHEN jsonb_typeof(p_body#>'{stats,getInPrice}') = 'number' THEN (p_body#>>'{stats,getInPrice}')::numeric END,
           'price_max', CASE WHEN jsonb_typeof(p_body#>'{stats,maxPrice}') = 'number' THEN (p_body#>>'{stats,maxPrice}')::numeric END,
           'order_min', (SELECT lim.omin FROM lim),
           -- the cap a capped block shows; else the club's own, from provenue_watch_config.club_order_max (mig
           -- 20261128050000), passed in with the schedule row
           'order_max', coalesce((SELECT lim.omax FROM lim),
                                 CASE WHEN p_game->>'order_max' ~ '^[0-9]+$' THEN (p_game->>'order_max')::int END),
           'ok', true))
         || jsonb_build_object('listings', coalesce((SELECT jsonb_agg(jsonb_build_object('id', u.id) || u.row ORDER BY u.id) FROM u), '[]'::jsonb))
$function$;

REVOKE ALL ON FUNCTION public.provenue_watch_game(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provenue_capture_event(jsonb, text, jsonb) FROM PUBLIC, anon, authenticated;

COMMIT;
