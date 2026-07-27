-- SeatGeek BROKER DATA API rebuild — replaces the prior public-API
-- integration (mig 20260509080000) which used the wrong host.
-- Applied to prod 2026-05-09 ~02:35 UTC.
--
-- Why scrap+rebuild: the prior integration assumed `api.seatgeek.com/2`
-- (public discovery API with `?client_id=` auth). Our partner token is
-- actually for `brokerdata.seatgeek.com` (Seller Direct Broker Data API
-- with `?token=` auth). Different host, different endpoints, different
-- shape. The public-API tables (xref-by-event-id, taxonomies, sections,
-- recommendations) are not reachable with the broker token, so they're
-- dead weight. Drop and rebuild around what we CAN access:
--
--   GET /listings        — broker-only listings for an event_id
--   GET /v2/listings     — ALL secondary listings on SG marketplace for an event
--   GET /sales           — sales (transacted) for an event (broker-side)
--   GET /purchases       — broker's own SG purchases (token currently lacks
--                          this scope; revisit if SG enables it)
--
-- Auth: ?token=<TOKEN>. Our token is in vault as SEATGEEK_API_TOKEN.
--
-- ID mapping: SG event_id is independent. The broker API has NO search
-- endpoint, so matching tevo_event_id -> sg_event_id is manual. The
-- existing seatgeek_event_xref table covers this — we keep it but
-- simplify the schema to only what's relevant (drop public-API fields
-- like sg_url, sg_short_title, sg_taxonomies, sg_score, sg_announce_date
-- — none of those are exposed by the broker API).
--
-- Listings response shape (note: many fields are 1-2 char codes per spec):
--   ada       wheelchair / handicap accessible details
--   bo        broker-owned (true = listed by THIS account)
--   bp        broadcast_price (wholesale)
--   dm        delivery_method
--   ds        DealQuality score
--   id        display id (string)
--   idl       instant download
--   ihd       in-hand date
--   is_b2b    sourced from B2B exchange
--   lv        limited view
--   m         market (source ticket exchange)
--   pf        all-in retail price (per ticket, incl fees + delivery, no tax)
--   pn        seller notes
--   q         quantity
--   r         row
--   s         section
--   sglid     SeatGeek Listing ID (UNIQUE per listing — the right dedup key)
--   sp        splits (array of allowed split sizes)
--   sro      GA / standing-room-only
--   st        stock_type
--   wa        wheelchair accessible
--
-- Sales response shape:
--   bp        broadcast_price (wholesale at sale time)
--   dm        delivery method
--   id        sale UUID
--   idl       instant sale
--   ihd       in-hand date
--   pn        seller notes
--   putc      purchase UTC time (the sale timestamp)
--   q         quantity
--   r         row
--   s         section
--   st        stock type
--
-- Note: sales response does NOT include retail price — only broadcast/wholesale.

BEGIN;

-- 1. Drop prior public-API tables (introduced in mig 20260509080000)
DROP VIEW  IF EXISTS public.seatgeek_event_latest CASCADE;
DROP TABLE IF EXISTS public.seatgeek_recommendations CASCADE;
DROP TABLE IF EXISTS public.seatgeek_event_sections CASCADE;
DROP TABLE IF EXISTS public.seatgeek_taxonomies CASCADE;
DROP TABLE IF EXISTS public.seatgeek_performer_xref CASCADE;
DROP TABLE IF EXISTS public.seatgeek_venue_xref CASCADE;
DROP TABLE IF EXISTS public.seatgeek_event_xref CASCADE;
DROP TABLE IF EXISTS public.seatgeek_pull_log CASCADE;

-- 2. event_xref — simpler, broker-API-only fields
CREATE TABLE seatgeek_event_xref (
  tevo_event_id     bigint PRIMARY KEY,
  sg_event_id       bigint NOT NULL,
  sg_event_name     text,                  -- "Big 12 ... Texas vs Oklahoma"
  sg_event_type     text,                  -- "ncaa_football", "nba", etc.
  sg_event_location text,                  -- "AT&T Stadium" — SG returns location string
  sg_start_data     timestamptz,           -- (typo in SG spec — they call it "start_data")
  sg_visible_until  timestamptz,           -- when SG hides this event from marketplace
  matched_at        timestamptz NOT NULL DEFAULT NOW(),
  match_method      text NOT NULL DEFAULT 'manual',  -- manual | auto_url
  match_confidence  numeric,
  meta              jsonb DEFAULT '{}'::jsonb,
  last_listings_at  timestamptz,
  last_sales_at     timestamptz
);
CREATE INDEX idx_sg_event_xref_sg ON seatgeek_event_xref(sg_event_id);

-- 3. Listings snapshots — broker inventory for an event. One row per
--    (sglid, captured_at) pair so we keep the full history. Dedup by
--    sglid + content_hash so re-pulling unchanged listings doesn't bloat.
CREATE TABLE seatgeek_listings_snapshots (
  id              bigserial PRIMARY KEY,
  tevo_event_id   bigint NOT NULL,
  sg_event_id     bigint NOT NULL,
  captured_at     timestamptz NOT NULL DEFAULT NOW(),
  -- SG-side identity
  sglid           bigint,                 -- SeatGeek Listing ID (canonical)
  display_id      text,                   -- the "id" field (display only)
  -- Pricing
  retail_price_all_in  numeric,           -- pf
  broadcast_price      numeric,           -- bp (wholesale)
  deal_quality_score   numeric,           -- ds
  -- Inventory
  quantity        int,                    -- q
  splits          jsonb,                  -- sp (array of allowed splits)
  section         text,                   -- s
  row             text,                   -- r
  -- Flags
  is_broker_owned   boolean,              -- bo (THIS account's listing)
  is_b2b            boolean,              -- is_b2b
  is_instant_download boolean,            -- idl
  is_sro            boolean,              -- sro
  has_limited_view  boolean,              -- lv
  is_wheelchair_acc boolean,              -- wa
  ada_details       text,                 -- ada
  -- Logistics
  delivery_method  text,                  -- dm
  in_hand_date     date,                  -- ihd
  market_source    text,                  -- m
  stock_type       text,                  -- st
  seller_notes     text,                  -- pn
  -- Audit
  endpoint        text NOT NULL DEFAULT 'v1',  -- 'v1' = /listings, 'v2' = /v2/listings (broader)
  content_hash    text NOT NULL,
  raw             jsonb,
  CONSTRAINT seatgeek_listings_dedup UNIQUE (tevo_event_id, sglid, content_hash)
);
CREATE INDEX idx_sg_listings_event_at ON seatgeek_listings_snapshots(tevo_event_id, captured_at DESC);
CREATE INDEX idx_sg_listings_sglid    ON seatgeek_listings_snapshots(sglid, captured_at DESC);
CREATE INDEX idx_sg_listings_owned    ON seatgeek_listings_snapshots(tevo_event_id, is_broker_owned)
  WHERE is_broker_owned = true;

-- 4. Sales snapshots — transacted sales for an event. Sales are immutable
--    historical events; dedup by sale id (UUID per docs).
CREATE TABLE seatgeek_sales_snapshots (
  id              bigserial PRIMARY KEY,
  tevo_event_id   bigint NOT NULL,
  sg_event_id     bigint NOT NULL,
  pulled_at       timestamptz NOT NULL DEFAULT NOW(),
  -- SG-side identity
  sg_sale_id      text,                   -- the "id" UUID
  -- Pricing
  broadcast_price numeric,                -- bp (no retail price returned by /sales)
  -- Inventory snapshot at sale
  quantity        int,                    -- q
  section         text,                   -- s
  row             text,                   -- r
  stock_type      text,                   -- st
  delivery_method text,                   -- dm
  in_hand_date    date,                   -- ihd
  is_instant      boolean,                -- idl
  seller_notes    text,                   -- pn
  -- Sale timing
  sale_at_utc     timestamptz NOT NULL,   -- putc
  -- Audit
  raw             jsonb,
  CONSTRAINT seatgeek_sales_dedup UNIQUE (tevo_event_id, sg_sale_id)
);
CREATE INDEX idx_sg_sales_event_at ON seatgeek_sales_snapshots(tevo_event_id, sale_at_utc DESC);

-- 5. Pull log — audit trail for every broker API call
CREATE TABLE seatgeek_pull_log (
  id              bigserial PRIMARY KEY,
  called_at       timestamptz NOT NULL DEFAULT NOW(),
  endpoint        text NOT NULL,          -- '/listings' | '/v2/listings' | '/sales' | '/purchases'
  tevo_event_id   bigint,
  sg_event_id     bigint,
  http_status     int,
  rows_returned   int,
  cache_hit       boolean,                -- from response.cache_hit
  refreshed_at_utc timestamptz,           -- from response.refreshed_at_utc
  error_message   text,
  request_meta    jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX idx_sg_log_called_at ON seatgeek_pull_log(called_at DESC);
CREATE INDEX idx_sg_log_event ON seatgeek_pull_log(tevo_event_id, called_at DESC);

-- 6. Convenience view: latest broker-side state per linked event
CREATE OR REPLACE VIEW public.seatgeek_event_latest AS
SELECT
  x.tevo_event_id,
  x.sg_event_id,
  x.sg_event_name,
  x.sg_event_location,
  x.sg_start_data,
  x.last_listings_at,
  x.last_sales_at,
  -- Latest snapshot rollup (per pull, not per listing)
  (SELECT COUNT(DISTINCT sglid) FROM seatgeek_listings_snapshots ls
   WHERE ls.tevo_event_id = x.tevo_event_id
     AND ls.captured_at = (SELECT MAX(captured_at) FROM seatgeek_listings_snapshots
                            WHERE tevo_event_id = x.tevo_event_id)) AS active_listings,
  (SELECT SUM(quantity) FROM seatgeek_listings_snapshots ls
   WHERE ls.tevo_event_id = x.tevo_event_id
     AND ls.captured_at = (SELECT MAX(captured_at) FROM seatgeek_listings_snapshots
                            WHERE tevo_event_id = x.tevo_event_id)) AS active_tickets,
  (SELECT COUNT(*) FROM seatgeek_listings_snapshots ls
   WHERE ls.tevo_event_id = x.tevo_event_id
     AND ls.is_broker_owned = true
     AND ls.captured_at = (SELECT MAX(captured_at) FROM seatgeek_listings_snapshots
                            WHERE tevo_event_id = x.tevo_event_id)) AS broker_owned_listings,
  (SELECT COUNT(*) FROM seatgeek_sales_snapshots ss
   WHERE ss.tevo_event_id = x.tevo_event_id) AS sales_count,
  (SELECT MAX(sale_at_utc) FROM seatgeek_sales_snapshots ss
   WHERE ss.tevo_event_id = x.tevo_event_id) AS last_sale_at
FROM seatgeek_event_xref x;

-- 7. Grants
GRANT SELECT, INSERT, UPDATE ON seatgeek_event_xref         TO service_role;
GRANT SELECT, INSERT          ON seatgeek_listings_snapshots TO service_role;
GRANT SELECT, INSERT          ON seatgeek_sales_snapshots    TO service_role;
GRANT SELECT, INSERT          ON seatgeek_pull_log           TO service_role;
GRANT SELECT ON seatgeek_event_xref         TO authenticated;
GRANT SELECT ON seatgeek_listings_snapshots TO authenticated;
GRANT SELECT ON seatgeek_sales_snapshots    TO authenticated;
GRANT SELECT ON seatgeek_event_latest       TO authenticated, service_role;

COMMIT;
