-- Migration 20261125184500 · level:data-collection · lane:A1 (box-office collector) + D0 (the feed's view) · writes:v_primary_poll_listings_feed(re-created, same columns) · reads:primary_poll_listing · pre:20261125180000
--
-- THE ADA FILTER DROPPED EVERY LISTING WITHOUT A TICKET TYPE.
-- Operator 2026-11-25: "Fix the Timberwolves wheelchair filter".
--
-- Mig 20261125180000 withheld accessible seats with NOT (coalesce(ada, false) OR ticket_type = 'ACCESSIBLE').
-- When ticket_type is NULL and ada is false that is NOT (false OR NULL) = NULL, and a WHERE drops a NULL row. The
-- Timberwolves site gives no ticket type, so all 15,145 Timberwolves listings (29 games) left /primary/listings from
-- 17:51 UTC, when that migration was applied, with 155 AXS listings that also have none. The scraper kept reading;
-- only the feed was empty. Now a NULL ticket type counts as "not ACCESSIBLE". Nothing else changes: accessible seats
-- stay withheld (send_ada false), same columns.
--
-- Already applied to prod 2026-11-25 ~18:50 UTC (operator, as quoted). Verified after: timberwolves 29 games, 16,914 listings,
-- 53,924 tickets back in the feed; 139 AXS listings with no type back; 0 accessible seats sent by any source. Re-apply is a no-op.
-- rollback: re-create the view from mig 20261125180000.

BEGIN;

CREATE OR REPLACE VIEW public.v_primary_poll_listings_feed
WITH (security_invoker = true) AS
SELECT l.source,
       l.source_event_id AS event_id,
       t.name AS event_name,
       t.tevo_event_id,
       t.event_date,
       t.start_local_time,
       CASE WHEN p.part IS NOT NULL THEN l.listing_id || '-' || p.part ELSE l.listing_id END AS listing_id,
       l.market,
       l.area,
       l.section,
       l.seat_row,
       CASE WHEN p.part IS NOT NULL THEN p.seat_low  ELSE l.seat_low  END AS seat_low,
       CASE WHEN p.part IS NOT NULL THEN p.seat_high ELSE l.seat_high END AS seat_high,
       CASE WHEN p.part IS NOT NULL THEN p.seats     ELSE l.seats     END AS seats,
       CASE WHEN p.part IS NOT NULL THEN p.quantity  ELSE l.quantity  END AS quantity,
       CASE WHEN p.part IS NOT NULL AND jsonb_typeof(l.allowed_quantities) = 'array'
            THEN (SELECT jsonb_agg(q.v ORDER BY q.i)
                    FROM jsonb_array_elements(l.allowed_quantities) WITH ORDINALITY q(v, i)
                   WHERE jsonb_typeof(q.v) = 'number'
                     AND ((q.v #>> '{}'))::numeric <= (least(l.order_limit, p.quantity))::numeric)
            ELSE l.allowed_quantities END AS allowed_quantities,
       CASE WHEN p.part IS NOT NULL THEN least(l.order_limit, p.quantity)
            WHEN l.order_limit IS NOT NULL THEN least(l.order_limit, l.quantity)
            ELSE l.max_per_order END AS max_per_order,
       t.order_min,
       t.order_max,
       l.price,
       l.fee,
       l.all_in_price,
       l.price_includes_tax,
       t.currency,
       l.ticket_type,
       l.delivery,
       l.ada,
       l.aisle,
       l.general_admission,
       t.poll_ok_at AS as_of,
       l.tax,
       l.order_fee,
       l.price_estimated
  FROM public.primary_poll_listing l
  JOIN public.primary_poll_event t ON t.source = l.source AND t.source_event_id = l.source_event_id
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
  LEFT JOIN public.primary_poll_listing_piece p
         ON p.source = l.source AND p.source_event_id = l.source_event_id AND p.listing_id = l.listing_id
        AND (SELECT c.split_over_limit FROM public.primary_poll_config c)
 WHERE t.poll_status = 'ok'
   AND NOT public.primary_poll_ended(t.start_utc, t.event_date)
   AND now() < greatest(t.poll_ok_at + (SELECT c.listing_max_age FROM public.primary_poll_config c),
                        t.next_poll_at + (SELECT c.listing_grace FROM public.primary_poll_config c))
   AND NOT l.obstructed
   -- accessible seats are withheld: both signals, because ada alone misses 93% of them (mig 20261125180000); a NULL
   -- ticket_type (every Timberwolves listing) counts as not accessible, else the whole test is NULL and the row is dropped
   AND ((SELECT c.send_ada FROM public.primary_poll_config c)
        OR NOT (coalesce(l.ada, false) OR coalesce(l.ticket_type = 'ACCESSIBLE', false)))
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_listings_feed TO service_role;

COMMIT;
