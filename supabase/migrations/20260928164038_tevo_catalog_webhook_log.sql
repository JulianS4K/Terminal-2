-- Migration 20260928164038 · lane:A1 · writes:tevo_webhook_notifications · reads:none · pre:none
--
-- NOT applied to prod — authored only. Apply is operator-gated (CLAUDE.md §1).
--
-- ============================================================================
-- TEvo Catalog Notifications (webhooks) — inbound landing table.
--
-- Lane:     A1 (data plane — TEvo ingest)
-- Touches:  tevo_webhook_notifications (W)
-- Pre-reqs: edge fn `tevo-catalog-webhook` deployed with --no-verify-jwt and
--           its env secret TEVO_WEBHOOK_SECRET set; the full URL
--           (…/functions/v1/tevo-catalog-webhook?token=<secret>) handed to
--           TEvo support (they register it — we never call a TEvo write API).
--
-- TEvo POSTs application/x-www-form-urlencoded with `recipient`,
-- `event_type` and `body` (the entity JSON), plus one of `event_id` /
-- `performer_id` / `venue_id`. event_type is event_|performer_|venue_
-- {created,updated,deleted}. The URL is SHARED with TEvo Order
-- Notifications, so order_* (and any unknown) types land here too, tagged
-- entity_kind 'order' / 'other' — nothing is dropped.
--
-- This is a log/queue only: nothing reads it yet. `processed_at` is left
-- NULL for a follow-up consumer that folds rows into the TEvo mirror
-- (`events` / performers / venues). TEvo sends no notification id, so
-- retries dedupe on the sha256 of the raw request body.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tevo_webhook_notifications (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  received_at   timestamptz NOT NULL DEFAULT now(),
  body_sha256   text        NOT NULL UNIQUE,  -- retry dedupe (no upstream notification id)
  event_type    text        NOT NULL,         -- e.g. event_updated, performer_deleted, order_*
  entity_kind   text        NOT NULL
                CHECK (entity_kind IN ('event','performer','venue','order','other')),
  entity_id     bigint,                       -- TEvo-native id (event/performer/venue); NULL for order/other
  recipient     text,
  body          jsonb,                        -- parsed `body` field; NULL if it wasn't JSON
  body_raw      text,                         -- `body` verbatim when it didn't parse
  extra_fields  jsonb       NOT NULL DEFAULT '{}'::jsonb,  -- every other form field, verbatim
  source_ip     text,
  processed_at  timestamptz                   -- set by the (future) mirror consumer
);

COMMENT ON TABLE public.tevo_webhook_notifications IS
  'Inbound TEvo Catalog/Order Notification webhooks (edge fn tevo-catalog-webhook). One row per distinct POST; body_sha256 dedupes retries. entity_id is the TEvo-native id — it IS tevo_event_id/tevo_performer_id/tevo_venue_id for catalog rows. processed_at NULL = not yet folded into the mirror.';

CREATE INDEX IF NOT EXISTS tevo_webhook_notifications_received_at_idx
  ON public.tevo_webhook_notifications (received_at DESC);

CREATE INDEX IF NOT EXISTS tevo_webhook_notifications_entity_idx
  ON public.tevo_webhook_notifications (entity_kind, entity_id);

CREATE INDEX IF NOT EXISTS tevo_webhook_notifications_unprocessed_idx
  ON public.tevo_webhook_notifications (received_at)
  WHERE processed_at IS NULL;

-- Standard RLS lockdown — only service_role (the edge function) reads/writes.
ALTER TABLE public.tevo_webhook_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tevo_webhook_notifications FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.tevo_webhook_notifications TO service_role;
