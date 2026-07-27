-- Migration 20260603220000 · level:2 · lane:A1
-- writes: DROP the remaining 2 FKs on seatgeek_seller_listings (sg_event_id, tevo_event_id)
--
-- ============================================================
-- Completes the seller-listings ingest fix from `…200000`.
-- KEY INSIGHT: a FOREIGN KEY marked NOT VALID is STILL enforced on new INSERTs
-- (NOT VALID only skips validating PRE-EXISTING rows). So dropping the two *VALID*
-- FKs (aq_short_event_id, venue_short_id) in `…200000` was not enough — the live
-- insert then failed on `seatgeek_seller_listings_sg_event_id_fkey` (NOT VALID):
--   Key (sg_event_id)=(17873144) is not present in table "sg_events_canonical".
-- The seller feed (our own S4K inventory) references SG events/venues that are NOT
-- in our broker-discovered canonical/map tables, so referential FKs at insert time
-- are simply the wrong model for this raw async-mapped ingest firehose.
-- FIX: drop the remaining two FKs (sg_event_id, tevo_event_id). The columns stay and
-- are still populated best-effort for downstream joins; they're just no longer
-- enforced at write time. Verified: after this, sg_seller_process() ingests cleanly.
--
-- Already applied to prod. Applied via MCP apply_migration 2026-06-03 (A1, operator-directed).
-- ============================================================

ALTER TABLE public.seatgeek_seller_listings DROP CONSTRAINT IF EXISTS seatgeek_seller_listings_sg_event_id_fkey;
ALTER TABLE public.seatgeek_seller_listings DROP CONSTRAINT IF EXISTS seatgeek_seller_listings_tevo_event_id_fkey;
