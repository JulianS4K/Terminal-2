-- Migration 20261128030000 · level:data-collection · lane:a1 (ProVenue watch) · writes:provenue_capture_event()(replace) · reads:—
--
-- ProVenue events carry their order limit, as AXS and the Timberwolves do. Operator 2026-11-28: "look at how axs
-- sends out listings to crm, see what purchase limits we get from each of our pulls and mimic".
--
-- What each pull gives the CRM (GET /api/v1/subs/primary/events and /listings) as of the first ProVenue reads:
--   axs           event order_min / order_max from the event's price groups (4 to 14, mostly 8); listings
--                 their purchasable quantities
--   timberwolves  event order_max 6; listings their sellable quantities
--   sitickets     no event limit; each listing's own figure
--   provenue      no event limit (until this); each listing's sellableQuantities
-- ProVenue's page prints no limit, but the club's cap shows wherever a block holds more seats than can be bought at
-- once: of the first 12 games, the Marlins sold at most 9 of a block of 32, the Padres 8, the Pirates 14, the Rays
-- 19, the Giants 20; the Nationals sold every block whole, up to 33. The capture now sends that cap as the event's
-- order_max (and the smallest quantity any block sells as order_min) when a capped block shows it, and no order_max
-- when none does. primary_poll_limit already takes the event's order_max before the listing's own figure, so the
-- split of a block over its limit (mig 20261124230030) and every listing's max_per_order follow it unchanged.

BEGIN;

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
    SELECT jsonb_strip_nulls(jsonb_build_object(
             'id', concat_ws('|', l.j->>'section', l.j->>'row',
                             coalesce(l.seats[1] || '-' || l.seats[array_length(l.seats, 1)], 'q' || (l.j->>'quantity')),
                             coalesce(nullif(l.j->>'ticketType', ''), 'Regular Ticket')),
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
           'order_max', (SELECT lim.omax FROM lim),
           'ok', true))
         || jsonb_build_object('listings', coalesce((SELECT jsonb_agg(r.row) FROM r), '[]'::jsonb))
$function$;

REVOKE ALL ON FUNCTION public.provenue_capture_event(jsonb, text, jsonb) FROM PUBLIC, anon, authenticated;

COMMIT;
