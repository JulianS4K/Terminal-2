-- SeatGeek Seller Direct API integration — read-only ingest of OUR S4K
-- inventory + orders from sellerdirect-api.seatgeek.com.
-- Applied to prod 2026-05-09 ~02:50 UTC.
--
-- Why: probe of sellerdirect-api.seatgeek.com (different host from the
-- broker data API at brokerdata.seatgeek.com) revealed two
-- discovery-grade endpoints:
--   GET /listings                 — full S4K listings catalog across
--                                   ALL events. Each row carries SG
--                                   event_id + event name + venue +
--                                   event_date inline → cures the
--                                   manual-matching problem entirely.
--   GET /orders?status={status}   — paginated order list. Each order
--                                   includes event.seatgeek_event_id
--                                   + event.name + event.venue +
--                                   listing.{section,row,price,quantity}.
--   GET /order?order_id=X         — single order detail (the Apps Script's
--                                   primary call from email triggers).
--
-- Read-only: this is a pull-and-persist integration. No POSTs to SG.
--
-- ID-discovery model: orders + listings carry SG event_id + name + venue +
-- date inline. We auto-upsert into seatgeek_event_xref every time we
-- ingest a new SG event_id, fuzzy-matching to a TEvo event on
-- (occurs_at_local::date, venue_name) when possible. Events we have
-- inventory or orders on auto-link without any manual step.
--
-- Schemas:
--   seatgeek_seller_listings   — snapshot of /listings (one row per
--                                listing per pull; dedup via content_hash)
--   seatgeek_orders            — order header (state, sale_date, totals,
--                                event_inline, listing_inline, payment)
--   seatgeek_order_tickets     — per-ticket detail (some orders have
--                                multiple seats; barcodes go here)
--   seatgeek_seller_pull_log   — audit trail
--
-- Functions:
--   sg_attempt_event_xref(sg_event_id, sg_name, sg_date, sg_venue)
--     → tries to find a TEvo event matching (date, venue) and upserts
--       seatgeek_event_xref. Idempotent: re-running with the same SG
--       event_id is a no-op.

BEGIN;

-- 1. Seller-direct listings — full S4K catalog snapshot. Each tick of
--    the collector is one full pull; we keep snapshots so we can see
--    inventory changes over time.
CREATE TABLE IF NOT EXISTS seatgeek_seller_listings (
  id              bigserial PRIMARY KEY,
  pulled_at       timestamptz NOT NULL DEFAULT NOW(),
  -- SG-side identity
  seller_listing_id  text,                 -- our internal id ("seller_listing_id")
  ticket_id          text,
  sg_listing_id      bigint,               -- SeatGeek's canonical listing id
  -- Event metadata (inline on every listing — discovery goldmine)
  sg_event_id        bigint NOT NULL,
  sg_event_name      text,
  sg_venue           text,
  sg_event_date      date,
  sg_event_time      text,
  -- Inventory
  quantity        int,
  section         text,
  row             text,
  seat_from       text,
  seat_thru       text,
  notes           text,                    -- "XFER", "PDF", etc.
  -- Pricing (cost = our wholesale; broadcast = SG's display ask)
  cost            numeric,
  -- Flags
  is_edelivery    boolean,
  is_instant      boolean,
  in_hand_date    date,
  -- Sale linkage
  tevo_event_id   bigint,                  -- backfilled via xref when matched
  -- Audit
  content_hash    text NOT NULL,
  raw             jsonb,
  CONSTRAINT seatgeek_seller_listings_dedup UNIQUE (sg_listing_id, content_hash)
);
CREATE INDEX IF NOT EXISTS idx_sg_sl_event       ON seatgeek_seller_listings(sg_event_id, pulled_at DESC);
CREATE INDEX IF NOT EXISTS idx_sg_sl_tevo_event  ON seatgeek_seller_listings(tevo_event_id, pulled_at DESC);
CREATE INDEX IF NOT EXISTS idx_sg_sl_sglid       ON seatgeek_seller_listings(sg_listing_id, pulled_at DESC);
CREATE INDEX IF NOT EXISTS idx_sg_sl_pulled_at   ON seatgeek_seller_listings(pulled_at DESC);

-- 2. Orders — order header. Status is whatever the list call's filter
--    was (open/confirmed/fulfilled/etc.) — we record it so we can detect
--    state transitions.
CREATE TABLE IF NOT EXISTS seatgeek_orders (
  id                       bigserial PRIMARY KEY,
  sg_order_id              text NOT NULL UNIQUE,        -- "q1g1cxd7d9"
  status                   text NOT NULL,               -- bucket the list call returned
  created_at_sg            timestamptz,
  delivery                 text,
  delivery_method          text,
  stock_type               text,
  fulfillment_issue_message text,
  pickup_email             text,
  pickup_phone             text,
  pickup_availability      text,
  pickup_location          text,
  pickup_instructions      text,
  -- Event metadata (inline on every order — discovery goldmine)
  sg_event_id              bigint,
  sg_event_name            text,
  sg_venue                 text,
  sg_event_date            date,
  sg_event_time            text,
  -- Listing snapshot at sale
  sg_listing_id            text,
  sale_price               numeric,                     -- listing.price
  sale_row                 text,
  sale_section             text,
  sale_quantity            int,
  -- Sale linkage to TEvo
  tevo_event_id            bigint,                      -- backfilled via xref
  -- Payment summary (when present)
  payment_total            numeric,
  payment_price            numeric,
  payment_fees             numeric,
  payment_tax              numeric,
  payment_delivery         numeric,
  -- Audit
  pulled_at                timestamptz NOT NULL DEFAULT NOW(),
  last_status_at           timestamptz NOT NULL DEFAULT NOW(),
  raw                      jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_orders_status     ON seatgeek_orders(status);
CREATE INDEX IF NOT EXISTS idx_sg_orders_event      ON seatgeek_orders(sg_event_id);
CREATE INDEX IF NOT EXISTS idx_sg_orders_tevo       ON seatgeek_orders(tevo_event_id);
CREATE INDEX IF NOT EXISTS idx_sg_orders_created    ON seatgeek_orders(created_at_sg DESC);

-- 3. Order tickets — per-seat detail (mobile passes, barcodes go here).
CREATE TABLE IF NOT EXISTS seatgeek_order_tickets (
  id              bigserial PRIMARY KEY,
  sg_order_id     text NOT NULL REFERENCES seatgeek_orders(sg_order_id) ON DELETE CASCADE,
  ticket_index    int NOT NULL,
  section         text,
  row             text,
  seat            text,
  is_ada          boolean,
  is_ga           boolean,
  obstructed_view boolean,
  barcode_type    text,
  barcode_value   text,
  mobile_passes   jsonb,
  raw             jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_order_tickets_order ON seatgeek_order_tickets(sg_order_id);

-- 4. Pull log — every collector tick gets a row per endpoint + status filter
CREATE TABLE IF NOT EXISTS seatgeek_seller_pull_log (
  id              bigserial PRIMARY KEY,
  called_at       timestamptz NOT NULL DEFAULT NOW(),
  endpoint        text NOT NULL,                       -- '/listings' | '/orders' | '/order'
  status_filter   text,                                -- the ?status= value, if any
  page            int,
  http_status     int,
  rows_returned   int,
  total_reported  int,                                 -- meta.total when present
  bytes           int,
  error_message   text,
  request_meta    jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_seller_log_called ON seatgeek_seller_pull_log(called_at DESC);

-- 5. Auto-backfill xref function. When SG metadata appears (event_id +
--    name + date + venue) on a listing or order, attempt to match a
--    TEvo event and upsert seatgeek_event_xref. Match heuristic:
--      step 1: exact venue_name (case-insensitive trim) AND occurs_at_local::date = sg_event_date
--      step 2: if multiple matches, pick the one whose name contains the SG event name's first word
--      step 3: if zero matches, store anyway with tevo_event_id = NULL so the user can manually fix
--    On success, also update last_listings_at or last_sales_at if those
--    are tracked.
CREATE OR REPLACE FUNCTION public.sg_attempt_event_xref(
  p_sg_event_id     bigint,
  p_sg_event_name   text,
  p_sg_event_date   date,
  p_sg_venue        text
) RETURNS bigint    -- returns matched tevo_event_id (or NULL if no match)
LANGUAGE plpgsql AS $$
DECLARE
  v_tevo_event_id bigint;
  v_existing      bigint;
BEGIN
  -- Already mapped? short-circuit, just keep meta fresh
  SELECT tevo_event_id INTO v_existing
  FROM seatgeek_event_xref WHERE sg_event_id = p_sg_event_id LIMIT 1;
  IF v_existing IS NOT NULL THEN
    UPDATE seatgeek_event_xref
       SET sg_event_name = COALESCE(p_sg_event_name, sg_event_name),
           sg_event_location = COALESCE(p_sg_venue, sg_event_location),
           sg_start_data = COALESCE(make_timestamptz(
                                      EXTRACT(YEAR FROM p_sg_event_date)::int,
                                      EXTRACT(MONTH FROM p_sg_event_date)::int,
                                      EXTRACT(DAY FROM p_sg_event_date)::int,
                                      0, 0, 0, 'UTC'), sg_start_data)
     WHERE sg_event_id = p_sg_event_id;
    RETURN v_existing;
  END IF;

  -- Step 1: exact venue + date match (ignoring case/whitespace).
  -- Some events have venues with subtle name variations; we LIKE-match
  -- the SG venue against TEvo venue_name as a tolerant fallback.
  SELECT id INTO v_tevo_event_id
  FROM events
  WHERE occurs_at_local::date = p_sg_event_date
    AND (
      lower(trim(venue_name)) = lower(trim(COALESCE(p_sg_venue, '')))
      OR lower(trim(venue_name)) LIKE lower(trim(COALESCE(p_sg_venue, ''))) || '%'
      OR lower(trim(COALESCE(p_sg_venue, ''))) LIKE lower(trim(venue_name)) || '%'
    )
  ORDER BY
    CASE WHEN lower(trim(venue_name)) = lower(trim(COALESCE(p_sg_venue, ''))) THEN 0 ELSE 1 END,
    -- prefer events whose name contains the first word of the SG name
    CASE WHEN p_sg_event_name IS NOT NULL
              AND lower(name) LIKE '%' || lower(split_part(p_sg_event_name, ' ', 1)) || '%' THEN 0
         ELSE 1 END
  LIMIT 1;

  -- Always insert/update the xref — if no TEvo match, tevo_event_id is NULL
  -- and shows in our system as "needs manual match"
  IF v_tevo_event_id IS NOT NULL THEN
    INSERT INTO seatgeek_event_xref (
      tevo_event_id, sg_event_id, sg_event_name, sg_event_type,
      sg_event_location, sg_start_data, match_method, match_confidence
    ) VALUES (
      v_tevo_event_id, p_sg_event_id, p_sg_event_name, NULL,
      p_sg_venue,
      make_timestamptz(
        EXTRACT(YEAR FROM p_sg_event_date)::int,
        EXTRACT(MONTH FROM p_sg_event_date)::int,
        EXTRACT(DAY FROM p_sg_event_date)::int, 0, 0, 0, 'UTC'),
      'auto_seller_inline', 0.85
    )
    ON CONFLICT (tevo_event_id) DO UPDATE
      SET sg_event_id = EXCLUDED.sg_event_id,
          sg_event_name = EXCLUDED.sg_event_name,
          sg_event_location = EXCLUDED.sg_event_location,
          sg_start_data = EXCLUDED.sg_start_data,
          matched_at = NOW();
  END IF;
  RETURN v_tevo_event_id;
END $$;

GRANT EXECUTE ON FUNCTION public.sg_attempt_event_xref(bigint, text, date, text)
  TO authenticated, service_role;

-- 6. Convenience view: orders rolled up per linked TEvo event
CREATE OR REPLACE VIEW public.seatgeek_orders_by_event AS
SELECT
  o.tevo_event_id,
  o.sg_event_id,
  COUNT(*) FILTER (WHERE o.status = 'open')      AS open_orders,
  COUNT(*) FILTER (WHERE o.status = 'pending')   AS pending_orders,
  COUNT(*) FILTER (WHERE o.status = 'confirmed') AS confirmed_orders,
  COUNT(*) FILTER (WHERE o.status = 'fulfilled') AS fulfilled_orders,
  COUNT(*) FILTER (WHERE o.status = 'delivered') AS delivered_orders,
  COUNT(*) FILTER (WHERE o.status = 'cancelled') AS cancelled_orders,
  SUM(o.sale_quantity) FILTER (WHERE o.status IN ('confirmed','fulfilled','delivered')) AS tickets_sold,
  SUM(o.sale_price * o.sale_quantity) FILTER (WHERE o.status IN ('confirmed','fulfilled','delivered')) AS gross_sold,
  MAX(o.last_status_at) AS last_order_at
FROM seatgeek_orders o
WHERE o.tevo_event_id IS NOT NULL
GROUP BY o.tevo_event_id, o.sg_event_id;

GRANT SELECT ON public.seatgeek_orders_by_event TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON seatgeek_seller_listings   TO service_role;
GRANT SELECT, INSERT, UPDATE ON seatgeek_orders            TO service_role;
GRANT SELECT, INSERT          ON seatgeek_order_tickets    TO service_role;
GRANT SELECT, INSERT          ON seatgeek_seller_pull_log  TO service_role;
GRANT SELECT ON seatgeek_seller_listings  TO authenticated;
GRANT SELECT ON seatgeek_orders           TO authenticated;
GRANT SELECT ON seatgeek_order_tickets    TO authenticated;

COMMIT;
