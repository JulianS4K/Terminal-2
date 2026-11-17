-- Migration 20260901183500 · level:secondary-sales · lane:D0 · writes:v_s4kcs_orders,cron · reads:s4kcs_orders,vivid_orders · pre:20260901183000
--
-- Expose the mapper's provenance on v_s4kcs_orders and run it after each drain.
--
-- The new columns are APPENDED, not inserted mid-list: CREATE OR REPLACE VIEW
-- cannot change an existing column's position or name (42P16), and dropping
-- the view would break its consumers (/api/broker/order-lookup and the D0/D2
-- deep-order fetcher, both of which select from it).
CREATE OR REPLACE VIEW public.v_s4kcs_orders AS
SELECT
  s.source, s.s4k_order_id, s.order_status, s.seller_status,
  s.event_name, s.event_date, s.venue_name, s.venue_city, s.venue_state,
  s.section, s.row, s.seats, s.quantity,
  COALESCE(s.price, v.total) AS price,
  s.price AS crm_price,
  CASE
    WHEN s.price IS NOT NULL THEN 'crm'
    WHEN v.total IS NOT NULL  THEN 'vivid_orders'
    ELSE NULL
  END AS price_source,
  s.delivery, s.inhand_date, s.payout_date, s.purchase_date, s.notes,
  -- s4kcs_map_events() writes the table columns; the vivid join stays as a
  -- late fallback for a row the mapper has not reached yet.
  COALESCE(s.tevo_event_id, v.tevo_event_id) AS tevo_event_id,
  COALESCE(s.aq_short_event_id, v.aq_short_event_id) AS aq_short_event_id,
  s.venue_short_id, s.performer_short_id,
  s.pulled_at, s.last_seen_at,
  s.map_method, s.map_confidence, s.mapped_at
FROM public.s4kcs_orders s
LEFT JOIN public.vivid_orders v
  ON s.source = 'Vivid Seats' AND v.vivid_order_id = s.s4k_order_id;

-- 3 minutes after each drain (drain is 3-59/10), so orders from a fresh pull
-- are resolved before anyone searches them. The function only fills rows whose
-- tevo_event_id is still NULL, so a re-run is cheap. Avoids the saturated
-- :02/:05/:07 minute marks.
SELECT cron.schedule(
  's4kcs_map_events_10min',
  '6-59/10 * * * *',
  'SELECT public.s4kcs_map_events();'
);
