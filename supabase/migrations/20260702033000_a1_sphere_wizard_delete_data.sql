-- ============================================================================
-- Migration 20260702033000 — Sphere Wizard of Oz: delete all data (supersedes archive)
--
-- Lane:     A1
-- Touches:  DROPs the five archive.sphere_* tables (created 20260702030000);
--           deletes Wizard rows from evo_listings_poll_state, seatgeek_event_xref,
--           sg_event_priority_state, sg_events_canonical.
-- Pre-reqs: 20260702030000 (the archive move this deletion supersedes).
--
-- WHY (operator 2026-07-02: "also delete all wizard of oz data"):
--   Supersedes the archive decision of 20260702030000 — the operator wants the
--   pseudo-event's data GONE, not retained cold. Deleted:
--     - archive.sphere_* (the ~9.85M archived rows: listings 8,823,403 +
--       section_metrics 920,127 + event_metrics 53,593 + SH-daily 49,918 +
--       zone_metrics 2,874) via DROP TABLE — instant, no bloat.
--     - evo_listings_poll_state    529 rows (poller clocks)
--     - seatgeek_event_xref        149 rows (FK-blocked canonical delete)
--     - sg_event_priority_state    448 rows (the SKIP tombstones)
--     - sg_events_canonical        448 rows (incl. the 395 TEvo mappings)
--
--   DELIBERATELY KEPT (exclusion config, not data):
--     - the 582 `events` rows with state='ignored' — the ignore-list tombstone.
--       Deleting them would let the next TEvo catalog sync re-create the events
--       with state NULL and re-enter them into polling.
--     - the deactivated td_sg_performers row (active=false) — blocks SG
--       re-discovery.
--     - the empty `archive` schema — the pattern stays for future exclusions.
--
--   Re-ingest safety without the SKIP rows: SG discovery for performer 123021
--   is deactivated and the canonical rows are gone, so nothing feeds the
--   classifier; if discovery is ever re-activated for this performer the events
--   would need re-discovery + re-matching first, which is operator-gated.
--
-- Idempotent: DROP IF EXISTS + deletes match 0 rows on re-run.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

DROP TABLE IF EXISTS archive.sphere_listings_snapshots;
DROP TABLE IF EXISTS archive.sphere_section_metrics;
DROP TABLE IF EXISTS archive.sphere_event_metrics;
DROP TABLE IF EXISTS archive.sphere_zone_metrics;
DROP TABLE IF EXISTS archive.sphere_event_listing_snapshot_daily;

WITH sphere AS (SELECT id FROM events WHERE primary_performer_id = 123021),
wiz AS (SELECT sg_event_id FROM sg_events_canonical WHERE sg_event_name ILIKE '%wizard of oz%'),
d1 AS (DELETE FROM evo_listings_poll_state WHERE event_id IN (SELECT id FROM sphere) RETURNING 1),
d2 AS (DELETE FROM seatgeek_event_xref WHERE sg_event_id IN (SELECT sg_event_id FROM wiz) RETURNING 1),
d3 AS (DELETE FROM sg_event_priority_state WHERE sg_event_id IN (SELECT sg_event_id FROM wiz) RETURNING 1)
DELETE FROM sg_events_canonical WHERE sg_event_name ILIKE '%wizard of oz%';
