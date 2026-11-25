-- Migration 20261124230000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:axs_watch_parse()(replaced),primary_poll_listing(AXS Premium rows removed),primary_poll_event(counts recomputed for those events) · reads:none · pre:20261124210000
--
-- AXS PREMIUM SEATS ARE NOT SHARED.
-- Operator 2026-11-24: "do not share premium listings with api to crm". AXS Premium is AXS's dynamically priced
-- product: the page prices each seat when a buyer selects it, and TicketsData's harvester carries only the seat's
-- static price level. Brent Faiyaz 12/11 at Crypto.com Arena, PR04 row 3 seats 1-4: the page sells each at $396.78
-- with fees; the body said $134.50 face, $158.70 all-in, and the number on the page appears nowhere in it. 1,095
-- primary listings (6,068 seats) over 29 events carried such a price. Now a primary listing whose seat type or
-- status label says AXS Premium is left out of the parse, the rows already ingested are removed, and each touched
-- event's counts are recomputed from what remains. Resale listings carry their own price and stay, premium sections
-- included.
--
-- rollback: re-apply axs_watch_parse() from 20261124210000; the removed rows return on each event's next read.

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
       -- AXS Premium is priced per seat on the page; the body carries only the price level, so the seat is not shared
       AND NOT (coalesce(l->>'kind', 'primary') = 'primary'
                AND (coalesce(l->>'seat_type', '') ~* 'premium' OR coalesce(l->>'status', '') ~* 'axs premium'))
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

-- The AXS Premium rows already in the feed go, and each touched event's counts are recomputed from what remains,
-- the way primary_poll_ingest() computes them (the median and the listed quantity over unobstructed listings).
DO $$
DECLARE v_gone integer; v_events integer;
BEGIN
  CREATE TEMP TABLE axs_premium_gone ON COMMIT DROP AS
    SELECT source_event_id FROM public.primary_poll_listing
     WHERE source = 'axs' AND market = 'primary' AND coalesce(ticket_type, '') ~* 'premium';
  DELETE FROM public.primary_poll_listing
   WHERE source = 'axs' AND market = 'primary' AND coalesce(ticket_type, '') ~* 'premium';
  GET DIAGNOSTICS v_gone = ROW_COUNT;
  UPDATE public.primary_poll_event t
     SET listing_count   = coalesce(a.n, 0),
         median_price    = a.median,
         listed_quantity = coalesce(a.qty, 0),
         total_available = coalesce(a.total, 0),
         price_min       = a.pmin,
         price_max       = a.pmax
    FROM (SELECT g.source_event_id,
                 count(l.listing_id) FILTER (WHERE NOT l.obstructed) AS n,
                 round((percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(l.all_in_price, l.price)) FILTER (WHERE NOT l.obstructed))::numeric, 2) AS median,
                 sum(l.quantity) FILTER (WHERE NOT l.obstructed) AS qty,
                 sum(l.quantity) AS total, min(l.price) AS pmin, max(l.price) AS pmax
            FROM (SELECT DISTINCT source_event_id FROM axs_premium_gone) g
            LEFT JOIN public.primary_poll_listing l ON l.source = 'axs' AND l.source_event_id = g.source_event_id
           GROUP BY g.source_event_id) a
   WHERE t.source = 'axs' AND t.source_event_id = a.source_event_id AND t.poll_status = 'ok';
  GET DIAGNOSTICS v_events = ROW_COUNT;
  RAISE NOTICE 'axs watch: % AXS Premium listings removed, % events recomputed', v_gone, v_events;
END $$;
