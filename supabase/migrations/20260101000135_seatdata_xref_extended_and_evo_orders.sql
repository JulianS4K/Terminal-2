-- Cross-source mapping (SeatData ↔ TEvo) + EVO orders integration.
-- Applied to prod 2026-05-09; this file captures it for git parity.
--
-- WHY (mapping): SeatData and TEvo use different ids for everything —
-- event_id, performer_id, venue_id, zone names, section identifiers. We
-- already have seatdata_event_xref for events. This migration adds the
-- finer-grained pieces:
--   * seatdata_venue_xref         — TEvo venue_id ↔ SD std_venue_id (manual + auto)
--   * seatdata_performer_xref     — TEvo performer_id ↔ SD std_event_id-based linkage
--   * seatdata_zone_xref          — per-event zone label normalization
--   * seatdata_section_xref       — per-event section label normalization
--   * normalize_sd_listing(...)   — helper that returns canonical zone/section
--                                   for a SeatData row, falling back to
--                                   derive_zone_fallback() for unmapped rows.
--
-- Data caveat: SeatData sales rows can have quantity=0 or NULL when the
-- transacted quantity is unknown. The view sd_sales_normalized treats
-- quantity=0 as "unknown" and reports it as NULL alongside a flag.
--
-- WHY (orders): TEvo /v9/orders gives us the OWN brokerage's order book —
-- pending/accepted/rejected/completed orders with line items mapped to
-- ticket_groups and events. This is direct visibility into S4K's actual
-- sales pipeline, complementary to listings_snapshots (what's for sale)
-- and seatdata_sales_snapshots (the broader market). Schema:
--   evo_orders        — one row per order (state, totals, buyer/seller, client)
--   evo_order_items   — line items, mapped to TEvo event_id when resolvable
-- Cron pulls every 10 min via /api/admin/collect-orders (X-Cron-Secret gated).

BEGIN;

-- ============================================================
-- A. SeatData ↔ TEvo cross-source mapping
-- ============================================================

CREATE TABLE IF NOT EXISTS seatdata_venue_xref (
  tevo_venue_id     bigint PRIMARY KEY,
  sd_std_venue_id   bigint,
  sd_venue_name     text,
  sd_venue_slug     text,
  sd_venue_city     text,
  sd_venue_state    text,
  match_method      text NOT NULL DEFAULT 'manual', -- manual | auto_name | auto_slug
  match_confidence  numeric,
  matched_at        timestamptz NOT NULL DEFAULT NOW(),
  meta              jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sd_venue_xref_sd ON seatdata_venue_xref(sd_std_venue_id);

CREATE TABLE IF NOT EXISTS seatdata_performer_xref (
  tevo_performer_id bigint PRIMARY KEY,
  sd_std_event_id   bigint,                 -- SeatData calls this "performer/tour" id
  sd_performer_name text,
  match_method      text NOT NULL DEFAULT 'manual',
  match_confidence  numeric,
  matched_at        timestamptz NOT NULL DEFAULT NOW(),
  meta              jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sd_perf_xref_sd ON seatdata_performer_xref(sd_std_event_id);

-- Per-event zone normalization. SeatData's "100 Level" might map to TEvo
-- curated zone "Lower Bowl" for Knicks at MSG; for a different event the
-- same SD label might mean something else. So mapping is keyed by event.
CREATE TABLE IF NOT EXISTS seatdata_zone_xref (
  id                bigserial PRIMARY KEY,
  tevo_event_id     bigint NOT NULL,
  sd_zone           text NOT NULL,
  tevo_zone         text,                   -- canonical name in our zone system
  match_method      text NOT NULL DEFAULT 'manual', -- manual | auto_keyword | auto_section_overlap
  match_confidence  numeric,
  notes             text,
  created_at        timestamptz DEFAULT NOW(),
  CONSTRAINT seatdata_zone_xref_unique UNIQUE (tevo_event_id, sd_zone)
);

CREATE TABLE IF NOT EXISTS seatdata_section_xref (
  id                bigserial PRIMARY KEY,
  tevo_event_id     bigint NOT NULL,
  sd_section        text NOT NULL,
  tevo_section      text,
  tevo_zone         text,                   -- propagated from zone for convenience
  match_method      text NOT NULL DEFAULT 'manual',
  match_confidence  numeric,
  created_at        timestamptz DEFAULT NOW(),
  CONSTRAINT seatdata_section_xref_unique UNIQUE (tevo_event_id, sd_section)
);

-- Helper: normalize a SeatData listing's section/zone to our canonical form.
-- Lookup priority:
--   1. seatdata_section_xref (event-specific section mapping)
--   2. seatdata_zone_xref    (event-specific zone mapping)
--   3. derive_zone_fallback(section, row) — same heuristic used for TEvo listings
--   4. NULL (unmapped — UI can show as "unmapped" group)
CREATE OR REPLACE FUNCTION public.normalize_sd_listing(
  p_event_id bigint,
  p_sd_zone text,
  p_sd_section text,
  p_sd_row text DEFAULT NULL
) RETURNS TABLE(canonical_zone text, canonical_section text, source text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_zone text; v_section text;
BEGIN
  -- 1. Section-level mapping wins
  SELECT tevo_zone, tevo_section INTO v_zone, v_section
  FROM seatdata_section_xref
  WHERE tevo_event_id = p_event_id AND sd_section = p_sd_section
  LIMIT 1;
  IF v_zone IS NOT NULL OR v_section IS NOT NULL THEN
    canonical_zone := v_zone; canonical_section := v_section;
    source := 'section_xref'; RETURN NEXT; RETURN;
  END IF;

  -- 2. Zone-level mapping
  SELECT tevo_zone INTO v_zone
  FROM seatdata_zone_xref
  WHERE tevo_event_id = p_event_id AND sd_zone = p_sd_zone
  LIMIT 1;
  IF v_zone IS NOT NULL THEN
    canonical_zone := v_zone; canonical_section := p_sd_section;
    source := 'zone_xref'; RETURN NEXT; RETURN;
  END IF;

  -- 3. Fallback heuristic (already used for TEvo listings)
  v_zone := derive_zone_fallback(p_sd_section, p_sd_row);
  IF v_zone IS NOT NULL THEN
    canonical_zone := v_zone; canonical_section := p_sd_section;
    source := 'fallback'; RETURN NEXT; RETURN;
  END IF;

  -- 4. Unmapped
  canonical_zone := NULL; canonical_section := p_sd_section;
  source := 'unmapped'; RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION public.normalize_sd_listing(bigint, text, text, text)
  TO authenticated, service_role;

-- View: SeatData sales with normalized zone + quantity-null handling.
-- SeatData sometimes returns quantity=0 to mean "unknown" — we surface
-- that as NULL with an explicit flag so consumers don't get fooled into
-- thinking 0 tickets sold.
CREATE OR REPLACE VIEW public.sd_sales_normalized AS
SELECT
  s.id, s.tevo_event_id, s.sd_event_id,
  s.sale_timestamp, s.price,
  -- Quantity null-fix: 0 in SeatData means "unknown qty" per docs caveat
  CASE WHEN COALESCE(s.quantity, 0) <= 0 THEN NULL ELSE s.quantity END AS quantity,
  (COALESCE(s.quantity, 0) <= 0) AS quantity_unknown,
  s.zone   AS sd_zone,
  s.section AS sd_section,
  s.row    AS sd_row,
  norm.canonical_zone,
  norm.canonical_section,
  norm.source AS canonical_source
FROM seatdata_sales_snapshots s
LEFT JOIN LATERAL public.normalize_sd_listing(s.tevo_event_id, s.zone, s.section, s.row) norm ON true;

GRANT SELECT ON public.sd_sales_normalized TO authenticated, service_role;

-- ============================================================
-- B. EVO orders (TEvo /v9/orders)
-- ============================================================

CREATE TABLE IF NOT EXISTS evo_orders (
  evo_order_id          bigint PRIMARY KEY,
  state                 text,                 -- pending | accepted | rejected | completed | pending_substitution
  type                  text,                 -- Order | PurchaseOrder
  fraud_check_status    text,                 -- accepted | etc.
  total                 numeric,
  subtotal              numeric,
  tax                   numeric,
  shipping              numeric,
  service_fee           numeric,
  refunded              numeric,
  balance               numeric,
  additional_expense    numeric,
  reference             text,
  invoice_number        text,
  po_number             text,
  instructions          text,
  partner               boolean,
  -- Buyer side
  buyer_id              bigint,
  buyer_name            text,
  buyer_brokerage_id    bigint,
  buyer_brokerage_name  text,
  -- Seller side
  seller_id             bigint,
  seller_name           text,
  seller_brokerage_id   bigint,
  seller_brokerage_name text,
  -- Client (end customer)
  client_id             bigint,
  client_name           text,
  client_phone          text,
  client_email          text,
  -- Timestamps
  evo_created_at        timestamptz,
  evo_updated_at        timestamptz,
  hold_placed_at        timestamptz,
  hold_expires_at       timestamptz,
  -- Audit / raw
  pulled_at             timestamptz NOT NULL DEFAULT NOW(),
  last_seen_at          timestamptz NOT NULL DEFAULT NOW(),
  raw                   jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_evo_orders_state         ON evo_orders(state);
CREATE INDEX IF NOT EXISTS idx_evo_orders_type          ON evo_orders(type);
CREATE INDEX IF NOT EXISTS idx_evo_orders_evo_created   ON evo_orders(evo_created_at DESC);
CREATE INDEX IF NOT EXISTS idx_evo_orders_evo_updated   ON evo_orders(evo_updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_evo_orders_seller_office ON evo_orders(seller_id);
CREATE INDEX IF NOT EXISTS idx_evo_orders_buyer_office  ON evo_orders(buyer_id);

CREATE TABLE IF NOT EXISTS evo_order_items (
  id                          bigserial PRIMARY KEY,
  evo_order_id                bigint NOT NULL REFERENCES evo_orders(evo_order_id) ON DELETE CASCADE,
  evo_item_id                 bigint UNIQUE,
  quantity                    int,
  price                       numeric,
  -- Ticket group snapshot at time of order
  ticket_group_id             bigint,
  ticket_group_remote_id      text,
  ticket_group_office_id      bigint,
  ticket_group_section        text,
  ticket_group_row            text,
  ticket_group_seats          jsonb,
  ticket_group_quantity       int,                  -- may be null per TEvo
  ticket_group_retail_price   numeric,
  ticket_group_wholesale_price numeric,
  ticket_group_external_notes text,
  -- Event mapping (the key bit — links order line to our events table)
  event_id                    bigint,                -- TEvo event_id, FK-ish to events(id)
  event_name                  text,
  occurs_at                   timestamptz,
  venue_id                    bigint,
  venue_name                  text,
  -- E-ticket state
  eticket_available           boolean,
  eticket_delivery            text,
  eticket_downloaded_at       timestamptz,
  eticket_downloaded_by       bigint,
  -- Audit / raw
  pulled_at                   timestamptz NOT NULL DEFAULT NOW(),
  raw                         jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_evo_oi_event   ON evo_order_items(event_id);
CREATE INDEX IF NOT EXISTS idx_evo_oi_order   ON evo_order_items(evo_order_id);
CREATE INDEX IF NOT EXISTS idx_evo_oi_tg      ON evo_order_items(ticket_group_id);

-- Convenience view: orders grouped per event (for the broker terminal's
-- event detail page — show "you have N pending orders / M completed" badge)
CREATE OR REPLACE VIEW public.evo_orders_by_event AS
SELECT
  oi.event_id,
  COUNT(DISTINCT oi.evo_order_id) FILTER (WHERE o.state = 'pending')              AS pending_orders,
  COUNT(DISTINCT oi.evo_order_id) FILTER (WHERE o.state = 'accepted')             AS accepted_orders,
  COUNT(DISTINCT oi.evo_order_id) FILTER (WHERE o.state = 'rejected')             AS rejected_orders,
  COUNT(DISTINCT oi.evo_order_id) FILTER (WHERE o.state = 'completed')            AS completed_orders,
  COUNT(DISTINCT oi.evo_order_id) FILTER (WHERE o.state = 'pending_substitution') AS pending_sub_orders,
  SUM(oi.quantity)         FILTER (WHERE o.state IN ('accepted','completed'))      AS tickets_sold,
  SUM(oi.price * oi.quantity) FILTER (WHERE o.state IN ('accepted','completed'))   AS gross_sold,
  MAX(o.evo_updated_at)                                                           AS last_order_update_at
FROM evo_order_items oi
JOIN evo_orders o ON o.evo_order_id = oi.evo_order_id
WHERE oi.event_id IS NOT NULL
GROUP BY oi.event_id;

GRANT SELECT ON public.evo_orders_by_event TO authenticated, service_role;

COMMIT;
