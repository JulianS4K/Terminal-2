-- Migration 20261124210000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:axs_watch_parse()(replaced) · reads:none · pre:20261124200000
--
-- A LISTING'S `status` IS THE VENUE'S OWN LABEL, NOT A YES/NO.
-- Operator 2026-11-24: "Disney On Ice presents Jump In! 12/20 7:00pm | Crypto.com Arena has listings" — but the watch had
-- read the body as empty. TicketsData's body carried 338 listings (3,823 seats, its own summary agreed); every one had
-- status 'CA-OPEN', 'CA-ADA OPEN' or 'AXS VIP 1', the venue's seat-status labels, and mig 20261124200000 kept only
-- listings whose status said 'Available'. Both Garth Brooks dates at Target Center (72 listings, 875 seats), A Boogie at
-- PeoplesBank Arena and every Disney On Ice date were read as empty the same way. Now only an explicitly sold, held or
-- unavailable label leaves a listing out. Also left out: an offer named as parking, a pass or an upgrade (the Disney
-- "Magical Pass" add-on sat among the seats).
--
-- Applied to prod via MCP 2026-11-24 right after it was written; re-apply is a no-op.
-- rollback: re-apply axs_watch_parse() from 20261124200000.

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
       -- `status` is the venue's own seat-status label (Available, CA-OPEN, CA-ADA OPEN, AXS VIP 1, ...): only an
       -- explicitly sold / held / unavailable label leaves a listing out
       AND coalesce(l->>'status', '') !~* 'sold|\mhold\M|held|unavail|not available|killed'
       AND coalesce(l->>'offer_name', '') !~* 'parking|\mpass\M|upgrade'
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
