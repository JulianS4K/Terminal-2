-- Cross-source order status mapping — single canonical vocabulary across
-- SeatGeek seller-direct, EVO/TEvo /v9/orders, and SeatData /v0.3/salesdata.
-- Applied to prod 2026-05-09; this file captures it for git parity.
--
-- Why: we ingest from 3 sale sources, each with its own status taxonomy:
--   * EVO    /v9/orders: state in (pending | accepted | rejected | completed | pending_substitution)
--                        type in (Order | PurchaseOrder)
--                        fraud_check_status (accepted | etc.)
--   * SG     /orders?status=:  open | pending | confirmed | fulfilled | cancelled | delivered | pending_substitution
--   * SeatData /salesdata:  no status field — every row IS a completed sale
--
-- Cross-source "is this sale in flight or terminal?" used to require
-- per-source CASE statements scattered across queries. This migration
-- makes the mapping a first-class table + view so any analytical query
-- can JOIN to canonical states and proceed without per-source logic.
--
-- Canonical state machine (chosen for analytical utility, not theological purity):
--
--   pending          — order received, no seller action yet
--   accepted         — seller acknowledged, working fulfillment
--   substitution     — fulfilling broker rejected, awaiting substitute
--   rejected         — seller rejected outright
--   cancelled        — cancelled by either side (no fulfillment intended)
--   fulfilled        — sale finalized and delivered (e-tickets uploaded or shipment delivered)
--
-- Two boolean flags carried alongside:
--   is_terminal      — state will not transition again (rejected/cancelled/fulfilled = true)
--   is_sale_succeeded — sale completed in our favor (fulfilled = true)
--
-- The flags drive analytics:
--   * sale velocity = count(fulfilled) per hour bucketed
--   * fill rate = is_sale_succeeded / total
--   * cancel rate = (rejected OR cancelled) / total
--   * in-flight book = NOT is_terminal

BEGIN;

-- ============================================================
-- A. order_status_xref — the rosetta stone
-- ============================================================
CREATE TABLE IF NOT EXISTS order_status_xref (
  id                bigserial PRIMARY KEY,
  source            text NOT NULL,         -- 'evo' | 'seatgeek' | 'seatdata'
  source_status     text NOT NULL,         -- the actual value seen on the wire
  source_status_kind text DEFAULT 'state', -- 'state' | 'type' | 'fraud_check'
  canonical_status  text NOT NULL,         -- pending | accepted | substitution | rejected | cancelled | fulfilled
  is_terminal       boolean NOT NULL DEFAULT false,
  is_sale_succeeded boolean NOT NULL DEFAULT false,
  notes             text,
  created_at        timestamptz DEFAULT NOW(),
  CONSTRAINT order_status_xref_unique UNIQUE (source, source_status, source_status_kind)
);
CREATE INDEX IF NOT EXISTS idx_osx_canonical ON order_status_xref(canonical_status);

-- Seed the mapping. Every observed value from every source goes here.
INSERT INTO order_status_xref (source, source_status, canonical_status, is_terminal, is_sale_succeeded, notes) VALUES
  -- EVO TEvo /v9/orders.state
  ('evo',      'pending',                 'pending',      false, false, 'Order submitted; seller has not acted'),
  ('evo',      'accepted',                'accepted',     false, false, 'Seller accepted; awaiting fulfillment'),
  ('evo',      'rejected',                'rejected',     true,  false, 'Seller rejected outright'),
  ('evo',      'completed',               'fulfilled',    true,  true,  'Delivered (shipment OR e-tickets uploaded)'),
  ('evo',      'pending_substitution',    'substitution', false, false, 'Rejected by fulfilling broker, awaiting sub'),

  -- SeatGeek seller-direct /orders?status=
  ('seatgeek', 'open',                    'pending',      false, false, 'Created, not yet acted on'),
  ('seatgeek', 'pending',                 'pending',      false, false, 'Awaiting seller action'),
  ('seatgeek', 'confirmed',               'accepted',     false, false, 'Seller accepted, awaiting fulfillment'),
  ('seatgeek', 'fulfilled',               'fulfilled',    true,  true,  'Delivered to buyer (e-tickets or shipment)'),
  ('seatgeek', 'delivered',               'fulfilled',    true,  true,  'Physical delivery confirmed (subset of fulfilled)'),
  ('seatgeek', 'cancelled',               'cancelled',    true,  false, 'Cancelled outright'),
  ('seatgeek', 'pending_substitution',    'substitution', false, false, 'Awaiting substitute fulfillment'),

  -- SeatData — every row in seatdata_sales_snapshots is a completed transaction.
  -- We synthesize a single source_status='sold' for analytical consistency.
  ('seatdata', 'sold',                    'fulfilled',    true,  true,  'SeatData /salesdata returns only completed sales')
ON CONFLICT (source, source_status, source_status_kind) DO UPDATE
  SET canonical_status  = EXCLUDED.canonical_status,
      is_terminal       = EXCLUDED.is_terminal,
      is_sale_succeeded = EXCLUDED.is_sale_succeeded,
      notes             = EXCLUDED.notes;

GRANT SELECT ON order_status_xref TO authenticated, service_role;

-- ============================================================
-- B. canonical_order_status() helper — translate any source's status
-- ============================================================
CREATE OR REPLACE FUNCTION public.canonical_order_status(p_source text, p_source_status text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'canonical_status',  canonical_status,
    'is_terminal',       is_terminal,
    'is_sale_succeeded', is_sale_succeeded,
    'notes',             notes
  )
  FROM order_status_xref
  WHERE source = lower(p_source) AND source_status = p_source_status
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.canonical_order_status(text, text) TO authenticated, service_role;

-- ============================================================
-- C. unified_orders view — single rowset across all 3 sources with
--    canonical status applied. JOIN-key is (source, sg_order_id|evo_order_id|sd_sale_id).
-- ============================================================
CREATE OR REPLACE VIEW public.unified_orders AS
-- EVO TEvo
SELECT
  'evo'::text                                         AS source,
  o.evo_order_id::text                                AS source_order_id,
  o.tevo_event_id  AS tevo_event_id_resolved,         -- via evo_order_items below; subquery
  NULL::text                                          AS sg_event_id,    -- evo doesn't carry SG id
  o.state                                             AS source_status,
  xref.canonical_status,
  xref.is_terminal, xref.is_sale_succeeded,
  o.type                                              AS source_type,    -- Order vs PurchaseOrder
  -- Money: roll up line items
  (SELECT SUM(i.price * i.quantity) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id)        AS gross_value,
  (SELECT SUM(i.quantity)            FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id)        AS quantity,
  -- Buyer / seller
  o.buyer_name, o.seller_name, o.client_name,
  o.evo_created_at AS created_at,
  o.evo_updated_at AS updated_at,
  o.last_seen_at,
  -- Mapped event_id from line items (may differ across multi-event orders)
  (SELECT MIN(i.event_id) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS tevo_event_id
FROM evo_orders o
LEFT JOIN order_status_xref xref
       ON xref.source = 'evo' AND xref.source_status = o.state

UNION ALL
-- SeatGeek seller-direct
SELECT
  'seatgeek',
  o.sg_order_id,
  o.tevo_event_id,
  o.sg_event_id::text,
  o.status,
  xref.canonical_status,
  xref.is_terminal, xref.is_sale_succeeded,
  NULL,
  o.payment_total,
  o.sale_quantity,
  NULL, NULL, NULL,           -- SG broker API doesn't expose buyer/seller/client identity
  o.created_at_sg AS created_at,
  o.last_status_at AS updated_at,
  o.last_status_at,
  o.tevo_event_id
FROM seatgeek_orders o
LEFT JOIN order_status_xref xref
       ON xref.source = 'seatgeek' AND xref.source_status = o.status

UNION ALL
-- SeatData /v0.3/salesdata — every row IS a completed sale.
-- Source order id = content_hash (unique per sale row).
-- Note: this is `seatdata_sales_snapshots` (NOT seatgeek_sales_snapshots,
-- which is the SG broker-data /sales endpoint storage).
SELECT
  'seatdata',
  s.content_hash,
  s.tevo_event_id,
  NULL::text,                                   -- SeatData rows don't carry SG event_id
  'sold',
  'fulfilled',                                  -- canonical
  true, true,                                   -- is_terminal, is_sale_succeeded
  NULL,
  s.price * COALESCE(NULLIF(s.quantity, 0), 1)  AS gross_value,
  s.quantity,
  NULL, NULL, NULL,
  s.sale_timestamp, s.sale_timestamp, s.pulled_at
FROM seatdata_sales_snapshots s;

GRANT SELECT ON public.unified_orders TO authenticated, service_role;

-- ============================================================
-- D. Per-event rollup view — used by event hero + Order book page
-- ============================================================
CREATE OR REPLACE VIEW public.unified_orders_by_event AS
SELECT
  tevo_event_id,
  source,
  COUNT(*)                                                                       AS rows,
  COUNT(*) FILTER (WHERE NOT is_terminal)                                       AS in_flight,
  COUNT(*) FILTER (WHERE is_sale_succeeded)                                     AS fulfilled,
  COUNT(*) FILTER (WHERE canonical_status = 'rejected')                         AS rejected,
  COUNT(*) FILTER (WHERE canonical_status = 'cancelled')                        AS cancelled,
  COUNT(*) FILTER (WHERE canonical_status = 'pending')                          AS pending,
  COUNT(*) FILTER (WHERE canonical_status = 'accepted')                         AS accepted,
  COUNT(*) FILTER (WHERE canonical_status = 'substitution')                     AS substitution,
  SUM(gross_value)    FILTER (WHERE is_sale_succeeded)                          AS gross_sold,
  SUM(quantity)       FILTER (WHERE is_sale_succeeded)                          AS tickets_sold,
  MIN(created_at)                                                              AS first_order_at,
  MAX(updated_at)                                                              AS last_update_at
FROM unified_orders
WHERE tevo_event_id IS NOT NULL
GROUP BY tevo_event_id, source;

GRANT SELECT ON public.unified_orders_by_event TO authenticated, service_role;

-- ============================================================
-- E. Per-source totals (diagnostic)
-- ============================================================
CREATE OR REPLACE VIEW public.order_status_coverage AS
SELECT
  source,
  canonical_status,
  COUNT(*)                                AS rows,
  MIN(created_at)::date                   AS earliest,
  MAX(updated_at)::date                   AS latest,
  ROUND(AVG(quantity)::numeric, 2)        AS avg_qty,
  ROUND(SUM(gross_value)::numeric, 2)     AS sum_gross
FROM unified_orders
GROUP BY source, canonical_status
ORDER BY source, canonical_status;

GRANT SELECT ON public.order_status_coverage TO authenticated, service_role;

COMMIT;
