-- ============================================================================
-- Migration 20260509440000 — SG sales: record section/row, derive gross
--
-- Per directive: "sg probably not pushing total but we can still record
-- section/row of sale to event."
--
-- VERIFIED LIVE (2026-05-09):
--   400/400 SG orders have sale_section, sale_row, sale_quantity, sale_price
--   0/400 have payment_total or payment_price (SG API doesn't return them)
--   400/400 orders link to sg_events_canonical (clean event xref)
--
-- WHAT THIS DOES:
--   (A) Update our_orders to derive gross_amount from sale_price * sale_quantity
--       when payment_total is NULL (the new default for sg_seller).
--   (B) Build v_sg_sales_by_section — per-section sale detail per event.
--   (C) Build v_sg_sales_by_event — event-level rollup with median/sum.
-- ============================================================================

-- (A) Replace our_orders to use COALESCE(payment_total, sale_price * sale_quantity)
CREATE OR REPLACE VIEW our_orders AS
SELECT
  'tevo'::text AS source,
  evo_order_id::text AS source_order_id,
  state AS source_status,
  COALESCE(
    (SELECT canonical_status FROM order_status_xref
     WHERE source = 'tevo' AND lower(source_status) = lower(evo_orders.state)
     LIMIT 1), 'unknown') AS canonical_status,
  total AS gross_amount,
  evo_created_at AS source_created_at,
  evo_updated_at AS source_updated_at,
  hold_expires_at,
  buyer_brokerage_name AS counterparty,
  (SELECT min(event_id) FROM evo_order_items WHERE evo_order_id = evo_orders.evo_order_id) AS tevo_event_id,
  pulled_at
FROM evo_orders
UNION ALL
SELECT
  'sg_seller'::text,
  sg_order_id, status,
  COALESCE(
    (SELECT canonical_status FROM order_status_xref
     WHERE source = 'sg_seller' AND lower(source_status) = lower(seatgeek_orders.status)
     LIMIT 1), 'unknown'),
  -- KEY CHANGE: derive gross from sale_price * sale_quantity since payment_total is NULL
  COALESCE(payment_total, (sale_price * sale_quantity))::numeric AS gross_amount,
  created_at_sg, last_status_at, NULL::timestamptz,
  delivery, tevo_event_id, pulled_at
FROM seatgeek_orders;

COMMENT ON VIEW our_orders IS
  'OUR own sales rolled up across TEvo + SG sellerdirect. SG payment_total '
  'is not returned by the API; we derive gross_amount from sale_price * '
  'sale_quantity which is always present. Subject to order_fee_schedule '
  'in our_orders_with_net for net-of-fees.';

-- (B) Per-section sale detail with TEvo event linkage
CREATE OR REPLACE VIEW v_sg_sales_by_section AS
SELECT
  so.tevo_event_id,
  so.sg_event_id,
  so.sg_event_name,
  so.sg_event_date,
  so.sg_venue,
  so.sale_section AS section,
  so.sale_row     AS row,
  so.sale_quantity,
  so.sale_price,
  (so.sale_price * so.sale_quantity)::numeric AS sale_total_estimate,
  so.status,
  so.created_at_sg,
  so.last_status_at,
  so.delivery_method,
  so.stock_type
FROM seatgeek_orders so
WHERE so.sale_section IS NOT NULL
ORDER BY so.created_at_sg DESC;

COMMENT ON VIEW v_sg_sales_by_section IS
  'Every SG sale with its section/row/qty/price + TEvo event xref where '
  'available. The section_total_estimate is sale_price * sale_quantity.';

-- (C) Event-level rollup
CREATE OR REPLACE VIEW v_sg_sales_by_event AS
SELECT
  tevo_event_id,
  sg_event_id,
  max(sg_event_name) AS sg_event_name,
  max(sg_event_date) AS sg_event_date,
  count(*)                                 AS sales_count,
  sum(sale_quantity)                       AS tickets_sold,
  sum(sale_price * sale_quantity)::numeric AS gross_estimate,
  min(sale_price)                          AS min_sale_price,
  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sale_price)::numeric, 2) AS median_sale_price,
  max(sale_price)                          AS max_sale_price,
  count(DISTINCT sale_section)             AS distinct_sections,
  string_agg(DISTINCT sale_section, ',' ORDER BY sale_section) AS sections,
  max(created_at_sg)                       AS latest_sale_at
FROM seatgeek_orders
WHERE sale_section IS NOT NULL
GROUP BY tevo_event_id, sg_event_id;

COMMENT ON VIEW v_sg_sales_by_event IS
  'Event-level rollup of SG sales. tickets_sold = sum of sale_quantity, '
  'gross_estimate = sum of sale_price * sale_quantity (best we can derive '
  'since payment_total is not returned). Median/min/max give the price '
  'distribution per event.';
