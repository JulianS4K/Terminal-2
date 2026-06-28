-- ============================================================================
-- Migration 20260626120000 — fix seatgeek_seller_listings NULL-key upsert dup
-- Already applied to prod · via MCP 2026-06-26 (operator-authorized; verified:
--   constraint now UNIQUE (sg_event_id, content_hash), 2859 rows intact, 0 dups).
--
-- Lane:     storefront (SeatGeek seller ingest)
-- Touches:  seatgeek_seller_listings (W — drop+recreate dedup unique, dedup rows)
-- Pre-reqs: none
--
-- BUGHUNT-1 (production-readiness P0 #3). The dedup unique was
-- UNIQUE (sg_listing_id, content_hash). sg_listing_id is nullable, and the
-- ingest (seatgeek_client.store_seller_listings) writes NULL when a seller
-- listing arrives without an sg_listing_id. In Postgres NULL <> NULL, so the
-- ON CONFLICT (sg_listing_id, content_hash) upsert never matches a NULL-keyed
-- row -> every re-pull INSERTs a fresh duplicate instead of refreshing it.
--
-- Fix: key the dedup on a NON-NULL composite, (sg_event_id, content_hash).
-- Both are always populated by the ingest (rows with NULL event_id are
-- skipped; content_hash is always computed AND already incorporates
-- sg_listing_id + every defining listing attribute). So this preserves the
-- "one row per (listing, content-version)" intent, fixes the NULL hole, and is
-- strictly safer across events (the old key ignored the event entirely).
--
-- The app upsert's on_conflict is repointed to "sg_event_id,content_hash" in
-- the same change (seatgeek_client.py). Apply this migration BEFORE deploying
-- that code so the new constraint exists when the new on_conflict runs.
-- ============================================================================

BEGIN;

-- 1. Defensive dedup: collapse any pre-existing (sg_event_id, content_hash)
--    duplicates, keeping the most-recently-pulled row. (Measured 0 on prod at
--    authoring time — this is a safety net so the unique index can be built.)
WITH ranked AS (
    SELECT id,
           row_number() OVER (
               PARTITION BY sg_event_id, content_hash
               ORDER BY pulled_at DESC, id DESC
           ) AS rn
    FROM public.seatgeek_seller_listings
    WHERE sg_event_id IS NOT NULL
      AND content_hash IS NOT NULL
)
DELETE FROM public.seatgeek_seller_listings s
USING ranked r
WHERE s.id = r.id
  AND r.rn > 1;

-- 2. Drop the broken NULL-prone unique and replace it with the non-null key.
ALTER TABLE public.seatgeek_seller_listings
    DROP CONSTRAINT IF EXISTS seatgeek_seller_listings_dedup;

ALTER TABLE public.seatgeek_seller_listings
    ADD CONSTRAINT seatgeek_seller_listings_dedup
    UNIQUE (sg_event_id, content_hash);

COMMIT;
