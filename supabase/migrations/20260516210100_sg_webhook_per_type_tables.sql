-- Migration 20260516210100 · lane:A1 (D2-authored) · writes:sg_seller_* (6 new tables) · reads:- · pre:20260516210000 · auth:operator-permitted 2026-05-16
-- WS2 part 2/3: per-type tables for SG SellerDirect webhook notifications.
-- One table per notification_type that isn't already covered by an existing
-- table. order.created continues to UPSERT into the existing seatgeek_orders
-- table (mig 20260509021125 et al.); ping is audit-only via
-- sg_seller_webhook_notifications_seen (mig 20260516210000).
-- All tables: standard RLS lockdown, service_role read+insert only.

-- ============================================================
-- 1. order.retransfer — buyer info per retransfer event
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sg_seller_order_retransfers (
  id                bigserial PRIMARY KEY,
  notification_id   uuid NOT NULL,
  seller_id         bigint,
  seller_order_id   text NOT NULL,
  buyer_email       text,
  buyer_first_name  text,
  buyer_last_name   text,
  buyer_phone       text,
  received_at       timestamptz NOT NULL DEFAULT now(),
  raw               jsonb,
  CONSTRAINT sg_seller_order_retransfers_uniq UNIQUE (seller_order_id, notification_id)
);
CREATE INDEX IF NOT EXISTS sg_seller_order_retransfers_order_idx
  ON public.sg_seller_order_retransfers (seller_order_id);
ALTER TABLE public.sg_seller_order_retransfers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sg_seller_order_retransfers FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.sg_seller_order_retransfers TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.sg_seller_order_retransfers_id_seq TO service_role;

-- ============================================================
-- 2. order.fulfillment.error — nested order/event/tokens shape
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sg_seller_order_fulfillment_errors (
  id                  bigserial PRIMARY KEY,
  notification_id     uuid NOT NULL UNIQUE,
  seller_id           bigint,
  external_order_id   text,
  sd_order_id         text,
  sg_event_id         bigint,
  event_name          text,
  event_date          text,
  event_venue         text,
  delivery_method     text,
  stock_type          text,
  section             text,
  row                 text,
  issue_code          text,
  issue_message       text,
  issue_developer_msg text,
  tokens              jsonb,    -- array of {seat, token, token_type, issue:{code,message,developer_message}}
  received_at         timestamptz NOT NULL DEFAULT now(),
  raw                 jsonb
);
CREATE INDEX IF NOT EXISTS sg_seller_order_fulfillment_errors_order_idx
  ON public.sg_seller_order_fulfillment_errors (external_order_id);
CREATE INDEX IF NOT EXISTS sg_seller_order_fulfillment_errors_event_idx
  ON public.sg_seller_order_fulfillment_errors (sg_event_id);
CREATE INDEX IF NOT EXISTS sg_seller_order_fulfillment_errors_recent_idx
  ON public.sg_seller_order_fulfillment_errors (received_at DESC);
ALTER TABLE public.sg_seller_order_fulfillment_errors ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sg_seller_order_fulfillment_errors FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.sg_seller_order_fulfillment_errors TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.sg_seller_order_fulfillment_errors_id_seq TO service_role;

-- ============================================================
-- 3. listing.event.inactive — listing→inactive-event linkage
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sg_seller_listing_inactive_events (
  id                  bigserial PRIMARY KEY,
  notification_id     uuid NOT NULL,
  seller_id           bigint,
  sg_listing_id       bigint NOT NULL,
  seller_listing_id   text NOT NULL,
  event_id            bigint NOT NULL,
  event_name          text,
  event_datetime      timestamptz,
  reason              text NOT NULL,   -- event_inactive | event_cancelled | event_past_visible_date | event_merged | event_not_found
  received_at         timestamptz NOT NULL DEFAULT now(),
  raw                 jsonb,
  CONSTRAINT sg_seller_listing_inactive_events_uniq UNIQUE (sg_listing_id, notification_id)
);
CREATE INDEX IF NOT EXISTS sg_seller_listing_inactive_events_seller_listing_idx
  ON public.sg_seller_listing_inactive_events (seller_listing_id);
CREATE INDEX IF NOT EXISTS sg_seller_listing_inactive_events_event_idx
  ON public.sg_seller_listing_inactive_events (event_id);
ALTER TABLE public.sg_seller_listing_inactive_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sg_seller_listing_inactive_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.sg_seller_listing_inactive_events TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.sg_seller_listing_inactive_events_id_seq TO service_role;

-- ============================================================
-- 4. listing.visibility — batched hidden-listing observations
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sg_seller_listing_visibility (
  id                       bigserial PRIMARY KEY,
  notification_id          uuid NOT NULL,
  seller_id                bigint,
  seller_listing_id        text NOT NULL,
  event_id                 bigint NOT NULL,
  hidden_reason_code       text,
  hidden_reason_description text,
  received_at              timestamptz NOT NULL DEFAULT now(),
  raw                      jsonb,
  CONSTRAINT sg_seller_listing_visibility_uniq UNIQUE (seller_listing_id, event_id, notification_id)
);
CREATE INDEX IF NOT EXISTS sg_seller_listing_visibility_recent_idx
  ON public.sg_seller_listing_visibility (received_at DESC);
CREATE INDEX IF NOT EXISTS sg_seller_listing_visibility_reason_idx
  ON public.sg_seller_listing_visibility (hidden_reason_code);
ALTER TABLE public.sg_seller_listing_visibility ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sg_seller_listing_visibility FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.sg_seller_listing_visibility TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.sg_seller_listing_visibility_id_seq TO service_role;

-- ============================================================
-- 5. listing.normalization.status — first-create normalization snapshot
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sg_seller_listing_normalization (
  id                  bigserial PRIMARY KEY,
  notification_id     uuid NOT NULL,
  seller_id           bigint,
  sg_listing_id       bigint NOT NULL,
  seller_listing_id   text NOT NULL,
  event_id            bigint,
  venue_id            bigint,
  map_config_id       int,
  section_raw         text,
  row_raw             text,
  section_normalized  text,
  row_normalized      text,
  mapkey              text,
  normalized          boolean,
  row_warning         text,
  seatgeek_notes      text,
  visible_on_map      boolean,
  received_at         timestamptz NOT NULL DEFAULT now(),
  raw                 jsonb,
  CONSTRAINT sg_seller_listing_normalization_uniq UNIQUE (sg_listing_id, notification_id)
);
CREATE INDEX IF NOT EXISTS sg_seller_listing_normalization_seller_listing_idx
  ON public.sg_seller_listing_normalization (seller_listing_id);
CREATE INDEX IF NOT EXISTS sg_seller_listing_normalization_unnormalized_idx
  ON public.sg_seller_listing_normalization (normalized) WHERE NOT normalized;
ALTER TABLE public.sg_seller_listing_normalization ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sg_seller_listing_normalization FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.sg_seller_listing_normalization TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.sg_seller_listing_normalization_id_seq TO service_role;

-- ============================================================
-- 6. listing.normalization.status.changed — unnormalized→normalized transitions
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sg_seller_listing_normalization_changes (
  id                    bigserial PRIMARY KEY,
  notification_id       uuid NOT NULL,
  seller_id             bigint,
  sg_listing_id         bigint NOT NULL,
  seller_listing_id     text NOT NULL,
  event_id              bigint,
  venue_id              bigint,
  map_config_id         int,
  previous_normalized   boolean,
  previous_row_warning  text,
  normalized            boolean,
  row_warning           text,
  seatgeek_notes        text,
  change_source         text,   -- map_config_update | stemming_rule_change | manual_rufus_action | seller_update
  received_at           timestamptz NOT NULL DEFAULT now(),
  raw                   jsonb,
  CONSTRAINT sg_seller_listing_normalization_changes_uniq UNIQUE (sg_listing_id, notification_id)
);
CREATE INDEX IF NOT EXISTS sg_seller_listing_normalization_changes_seller_listing_idx
  ON public.sg_seller_listing_normalization_changes (seller_listing_id);
CREATE INDEX IF NOT EXISTS sg_seller_listing_normalization_changes_recent_idx
  ON public.sg_seller_listing_normalization_changes (received_at DESC);
ALTER TABLE public.sg_seller_listing_normalization_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sg_seller_listing_normalization_changes FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.sg_seller_listing_normalization_changes TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.sg_seller_listing_normalization_changes_id_seq TO service_role;
