-- tickpick_orders + vivid_orders raw tables + order_status_xref rows.
-- Mirrors the evo_orders / seatgeek_orders shape: a raw table per source +
-- a *_pending queue table for the pg_net async ingest pattern (request_id
-- joins to net._http_response). The unified_orders view extension is in
-- the next migration (20260513230100); the ingest cron in 20260513230200.
--
-- Operator authorized 2026-05-13 ("do it") per CLAUDE.md global rule #1.
-- This migration is purely additive — no existing table or function is
-- modified. Safe to apply with zero downtime.

-- ============================================================
-- TickPick (JSON broker orders feed)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.tickpick_orders (
  tp_order_id      text PRIMARY KEY,
  event_name       text,
  event_date       timestamptz,
  section          text,
  row              text,
  seat_numbers     text[],
  status           text,
  quantity         int,
  total            numeric,
  notes            text,
  ordered_at       timestamptz,      -- order-created-at on TickPick's side, if surfaced (best-effort)
  tevo_event_id    bigint,           -- nullable; populated by cross-source matcher
  pulled_at        timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  raw              jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS tickpick_orders_event_date_idx
  ON public.tickpick_orders (event_date);
CREATE INDEX IF NOT EXISTS tickpick_orders_status_idx
  ON public.tickpick_orders (status);
CREATE INDEX IF NOT EXISTS tickpick_orders_tevo_event_id_idx
  ON public.tickpick_orders (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.tickpick_orders_pending (
  id              bigserial PRIMARY KEY,
  request_id      bigint NOT NULL,
  query_str       text,
  resolved_at     timestamptz,
  rows_persisted  int,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tickpick_orders_pending_unresolved_idx
  ON public.tickpick_orders_pending (resolved_at) WHERE resolved_at IS NULL;

-- RLS: service_role-only (matches evo_orders / seatgeek_orders posture).
ALTER TABLE public.tickpick_orders         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickpick_orders_pending ENABLE ROW LEVEL SECURITY;
-- No policies defined → anon/authenticated cannot SELECT. service_role
-- (used by d2_dashboard + the cron functions) bypasses RLS.

-- ============================================================
-- Vivid Seats (XML broker orders feed)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.vivid_orders (
  vivid_order_id     text PRIMARY KEY,
  event_name         text,
  event_date         timestamptz,
  section            text,
  row                text,
  status             text,
  quantity           int,
  total              numeric,
  first_name         text,
  last_name          text,
  email_address      text,
  transfer_via_url   boolean,
  ordered_at         timestamptz,
  tevo_event_id      bigint,           -- nullable; populated by cross-source matcher
  pulled_at          timestamptz NOT NULL DEFAULT now(),
  last_seen_at       timestamptz NOT NULL DEFAULT now(),
  raw_xml            text,             -- raw <order>...</order> snippet
  raw                jsonb NOT NULL DEFAULT '{}'::jsonb  -- parsed dict
);

CREATE INDEX IF NOT EXISTS vivid_orders_event_date_idx
  ON public.vivid_orders (event_date);
CREATE INDEX IF NOT EXISTS vivid_orders_status_idx
  ON public.vivid_orders (status);
CREATE INDEX IF NOT EXISTS vivid_orders_tevo_event_id_idx
  ON public.vivid_orders (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.vivid_orders_pending (
  id              bigserial PRIMARY KEY,
  request_id      bigint NOT NULL,
  query_str       text,
  resolved_at     timestamptz,
  rows_persisted  int,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS vivid_orders_pending_unresolved_idx
  ON public.vivid_orders_pending (resolved_at) WHERE resolved_at IS NULL;

ALTER TABLE public.vivid_orders         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vivid_orders_pending ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- order_status_xref additions
-- ============================================================

INSERT INTO public.order_status_xref
  (source, source_status, source_status_kind, canonical_status, is_terminal, is_sale_succeeded, notes)
VALUES
  -- TickPick — list_orders filter defaults to status=unfulfilled, so that's
  -- the row most likely to appear. Other terminal states aren't surfaced by
  -- the live list call but the xref covers them for completeness.
  ('tickpick', 'unfulfilled', 'state', 'accepted', false, false, 'Broker holds, awaiting delivery'),
  ('tickpick', 'pending',     'state', 'pending',  false, false, 'Awaiting seller action'),
  ('tickpick', 'fulfilled',   'state', 'fulfilled', true,  true, 'Delivered to buyer'),
  ('tickpick', 'filled',      'state', 'fulfilled', true,  true, 'Alias for fulfilled'),
  ('tickpick', 'cancelled',   'state', 'cancelled', true, false, 'Cancelled'),
  ('tickpick', 'canceled',    'state', 'cancelled', true, false, 'US-spelling alias'),
  ('tickpick', 'rejected',    'state', 'rejected',  true, false, 'Seller rejected'),
  -- Vivid Seats — getOrders + getPendingRetransferOrders feed these.
  ('vivid', 'PENDING_SHIPMENT',   'state', 'accepted',  false, false, 'Broker accepted, awaiting shipment'),
  ('vivid', 'PENDING_RETRANSFER', 'state', 'accepted',  false, false, 'Retransfer pending'),
  ('vivid', 'FULFILLED',          'state', 'fulfilled', true,  true, 'Delivered'),
  ('vivid', 'SHIPPED',            'state', 'fulfilled', true,  true, 'Shipment confirmed (subset of fulfilled)'),
  ('vivid', 'CANCELLED',          'state', 'cancelled', true, false, 'Cancelled'),
  ('vivid', 'CANCELED',           'state', 'cancelled', true, false, 'US-spelling alias'),
  ('vivid', 'REJECTED',           'state', 'rejected',  true, false, 'Rejected')
ON CONFLICT DO NOTHING;
