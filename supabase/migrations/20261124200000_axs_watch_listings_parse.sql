-- Migration 20261124200000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:axs_watch_parse()(replaced) · reads:none · pre:20261124190000
--
-- THE AXS WATCH READS TICKETSDATA'S OWN LISTINGS, NOT THE SEAT MANIFEST.
-- The first live reads of the watch (2026-11-24 19:46Z) showed what TicketsData's AXS body is today: 1.0–1.75 MB, a
-- seat manifest of about 2,000 seat items across 150–170 offers, AND a `listings` array of about 500 normalized
-- listings — each a block of adjoining seats (or a general-admission amount) with `kind` (primary | resale), section,
-- row, seats, quantity, `pricing` (face, the fees itemised, fees_total, tax, all_in), the offer, the price level, the
-- neighborhood and, for resale, `purchasable_quantities` and `original_price`; plus `listings_summary`. The seat-manifest
-- parser of mig 20261124190000 (written against the 2026-07 shape) took over 50 seconds on one of these bodies and the
-- tick timed out every minute, settling nothing. This replaces it with a parser of the `listings` array: a few hundred
-- rows, one pass, and the fees TicketsData already worked out — `fee` is no longer null and `all_in` is AXS's own total.
--
-- Mapping: price = pricing.face · fee = pricing.fees_total (resale: connection_fee) · all_in = pricing.all_in ·
-- tax = pricing.tax · market = kind · allowed_quantities = purchasable_quantities · area = neighborhood ·
-- ticket_type = seat_type · ada from the seat type or price level · obstructed from the price level or seller notes.
-- Left out: a listing that is not Available, a parking offer, a listing with no quantity. Order limits from `groups`
-- (ticket_qty min/max). A body with no `listings` array yields no listings (outcome 'empty').
--
-- Applied to prod via MCP 2026-11-24 right after it was written (operator: "merge and apply"); re-apply is a no-op.
-- rollback: re-apply axs_watch_parse() from 20261124190000.

CREATE OR REPLACE FUNCTION public.axs_watch_parse(p_body jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH raw AS (
    SELECT l
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'listings') = 'array' THEN p_body->'listings' ELSE '[]'::jsonb END) l
     WHERE coalesce(l->>'kind', 'primary') IN ('primary', 'resale')
       AND coalesce(l->>'status', 'Available') ~* 'available'
       AND coalesce(l->>'offer_name', '') !~* 'parking'
       AND coalesce(nullif(l->>'quantity', '')::integer,
                    CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN jsonb_array_length(l->'seats') END, 0) > 0),
  rows AS (
    SELECT coalesce(l->>'kind', 'primary') AS market, l->>'section' AS section, l->>'row' AS seat_row,
           CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN l->'seats' END AS seats,
           coalesce(nullif(l->>'quantity', '')::integer, CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN jsonb_array_length(l->'seats') END) AS qty,
           CASE WHEN jsonb_typeof(l->'purchasable_quantities') = 'array' THEN l->'purchasable_quantities' END AS allowed,
           nullif(l->'pricing'->>'face', '')::numeric AS price,
           coalesce(nullif(l->'pricing'->>'fees_total', '')::numeric, nullif(l->'pricing'->>'connection_fee', '')::numeric) AS fee,
           nullif(l->'pricing'->>'all_in', '')::numeric AS all_in,
           nullif(l->'pricing'->>'tax', '')::numeric AS tax,
           l->>'neighborhood' AS area, l->>'seat_type' AS ticket_type,
           coalesce((l->>'general_admission')::boolean, false) AS ga,
           (coalesce(l->>'seat_type', '') ~* 'ada|wheelchair' OR coalesce(l->>'price_level', '') ~* '\mada\M|wheelchair|accessible') AS ada,
           (coalesce(l->>'price_level', '') ~* 'obstruct|limited view' OR coalesce(l->>'seller_notes', '') ~* 'obstruct|limited view') AS obstructed,
           l->>'offer_id' AS offer_id
      FROM raw),
  listings AS (
    SELECT jsonb_strip_nulls(jsonb_build_object(
             'id', abs(hashtextextended(concat_ws('|', r.offer_id, r.market, r.section, r.seat_row, r.ticket_type,
                                                       coalesce(r.seats::text, r.qty::text), r.price::text), 0))::text,
             'market', r.market, 'section', r.section, 'row', r.seat_row,
             'seat_low', r.seats->>0, 'seat_high', r.seats->>-1, 'seats', r.seats, 'qty', r.qty,
             'allowed_quantities', r.allowed, 'price', r.price, 'fee', r.fee, 'all_in', r.all_in, 'tax', r.tax,
             'price_includes_tax', false, 'area', r.area, 'ticket_type', r.ticket_type,
             'ada', r.ada, 'obstructed', r.obstructed, 'ga', r.ga)) AS l,
           r.price, r.qty
      FROM rows r),
  groups AS (
    SELECT nullif(g->'ticket_qty'->>'min', '')::integer AS omin, nullif(g->'ticket_qty'->>'max', '')::integer AS omax
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'groups') = 'array' THEN p_body->'groups' ELSE '[]'::jsonb END) g)
  SELECT jsonb_build_object(
           'listings', coalesce((SELECT jsonb_agg(l.l ORDER BY l.l->>'section', l.l->>'row', l.l->>'id') FROM listings l), '[]'::jsonb),
           'price_min', (SELECT min(price) FROM listings),
           'price_max', (SELECT max(price) FROM listings),
           'total_available', (SELECT coalesce(sum(qty), 0) FROM listings),
           'order_min', (SELECT min(omin) FROM groups WHERE omin > 0),
           'order_max', (SELECT max(omax) FROM groups),
           'offer_id', nullif(p_body->'onsale'->>'offer_id', ''),
           'on_sale_now', (p_body->'onsale'->'status'->>'onSaleNow')::boolean,
           'summary', p_body->'listings_summary')
$function$;

REVOKE ALL ON FUNCTION public.axs_watch_parse(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_parse(jsonb) TO service_role;
