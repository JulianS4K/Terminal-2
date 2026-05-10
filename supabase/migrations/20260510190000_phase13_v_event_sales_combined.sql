-- ============================================================================
-- Phase 13: v_event_sales_combined — single server-side view that unifies
--           sales rows from EVO orders, SeatGeek seller orders, and the SG
--           broker sales snapshot for any Tevo event.
--
-- The event view's price chart plots one scatter dot per sale and the third
-- "Sales (combined)" raw-data tab paginates over the same rows. Doing this as
-- a single view (instead of three round-trips + client-side merge) keeps the
-- chart responsive under heavy snapshots.
--
-- Source legs:
--   src='EVO'        per-item rows from evo_order_items joined to evo_orders
--                    (one row per ticket-group line). is_ours=true.
--   src='SG_SELLER'  one row per confirmed/fulfilled/delivered sg seller order.
--                    is_ours=true.
--   src='SG_BROKER'  one row per distinct sg_sale_id from sales_snapshots
--                    (DISTINCT ON keeps the EARLIEST observation). is_ours=false.
--
-- Use:
--   SELECT * FROM v_event_sales_combined
--    WHERE tevo_event_id = :id
--      AND sold_at >= now() - INTERVAL '7 days'
--    ORDER BY sold_at DESC
--    LIMIT 200;
-- ============================================================================

DROP VIEW IF EXISTS v_event_sales_combined CASCADE;
CREATE VIEW v_event_sales_combined AS
WITH evo AS (
  SELECT
    'EVO'::text                                       AS src,
    oi.evo_order_id::text                             AS sale_id,
    oi.id::text                                       AS sale_line_id,
    oi.event_id                                       AS tevo_event_id,
    o.evo_created_at                                  AS sold_at,
    oi.ticket_group_section                           AS section,
    oi.ticket_group_row                               AS row_label,
    oi.quantity                                       AS qty,
    oi.price                                          AS price,
    oi.ticket_group_id                                AS ticket_group_id,
    TRUE                                              AS is_ours,
    o.state                                           AS order_state,
    jsonb_strip_nulls(jsonb_build_object(
      'evo_order_id',  oi.evo_order_id,
      'evo_item_id',   oi.evo_item_id,
      'seats',         oi.ticket_group_seats,
      'wholesale',     oi.ticket_group_wholesale_price,
      'retail',        oi.ticket_group_retail_price,
      'eticket',       oi.eticket_available
    ))                                                AS meta
  FROM evo_order_items oi
  JOIN evo_orders o ON o.evo_order_id = oi.evo_order_id
  WHERE oi.event_id IS NOT NULL
    AND o.state IN ('confirmed','fulfilled','delivered','complete','active')
),
sg_seller AS (
  SELECT
    'SG_SELLER'::text                                 AS src,
    sg_order_id::text                                 AS sale_id,
    sg_order_id::text                                 AS sale_line_id,
    tevo_event_id,
    COALESCE(created_at_sg, pulled_at)                AS sold_at,
    sale_section                                      AS section,
    sale_row                                          AS row_label,
    sale_quantity                                     AS qty,
    sale_price                                        AS price,
    NULL::bigint                                      AS ticket_group_id,
    TRUE                                              AS is_ours,
    status                                            AS order_state,
    jsonb_strip_nulls(jsonb_build_object(
      'sg_order_id',     sg_order_id,
      'sg_event_id',     sg_event_id,
      'sg_listing_id',   sg_listing_id,
      'delivery_method', delivery_method,
      'stock_type',      stock_type
    ))                                                AS meta
  FROM seatgeek_orders
  WHERE tevo_event_id IS NOT NULL
    AND status IN ('confirmed','fulfilled','delivered')
),
sg_broker AS (
  -- Snapshot table: same sg_sale_id may appear in multiple pulls. Keep the
  -- earliest (= when the sale first appeared in the broker fan).
  SELECT DISTINCT ON (sg_sale_id)
    'SG_BROKER'::text                                 AS src,
    sg_sale_id::text                                  AS sale_id,
    sg_sale_id::text                                  AS sale_line_id,
    tevo_event_id,
    COALESCE(sale_at_utc, pulled_at)                  AS sold_at,
    section,
    "row"                                             AS row_label,
    quantity                                          AS qty,
    broadcast_price                                   AS price,
    NULL::bigint                                      AS ticket_group_id,
    FALSE                                             AS is_ours,
    NULL::text                                        AS order_state,
    jsonb_strip_nulls(jsonb_build_object(
      'sg_sale_id',      sg_sale_id,
      'sg_event_id',     sg_event_id,
      'stock_type',      stock_type,
      'delivery_method', delivery_method,
      'is_instant',      is_instant,
      'in_hand_date',    in_hand_date
    ))                                                AS meta
  FROM seatgeek_sales_snapshots
  WHERE tevo_event_id IS NOT NULL AND sg_sale_id IS NOT NULL
  ORDER BY sg_sale_id, COALESCE(sale_at_utc, pulled_at) ASC
)
SELECT * FROM evo
UNION ALL
SELECT * FROM sg_seller
UNION ALL
SELECT * FROM sg_broker;

COMMENT ON VIEW v_event_sales_combined IS
  'Unified sales feed for the event view chart-scatter and Sales raw tab. '
  'One row per cleared sale: EVO per-item, SG seller per-order, SG broker '
  'per distinct sg_sale_id (earliest observation). Always filter by '
  'tevo_event_id for fast plans.';

GRANT SELECT ON v_event_sales_combined
  TO authenticated, anon, service_role;

-- ----------------------------------------------------------------------------
-- Supporting indexes for fast tevo_event_id + sold_at filtering.
-- IF NOT EXISTS keeps this safe to re-apply.
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS evo_order_items_event_id_idx
  ON evo_order_items (event_id);

CREATE INDEX IF NOT EXISTS seatgeek_orders_tevo_event_id_idx
  ON seatgeek_orders (tevo_event_id, created_at_sg DESC)
  WHERE tevo_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS seatgeek_sales_snapshots_tevo_event_id_idx
  ON seatgeek_sales_snapshots (tevo_event_id, sale_at_utc DESC NULLS LAST)
  WHERE tevo_event_id IS NOT NULL AND sg_sale_id IS NOT NULL;
