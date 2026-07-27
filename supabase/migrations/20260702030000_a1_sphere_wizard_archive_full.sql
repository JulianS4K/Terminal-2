-- ============================================================================
-- Migration 20260702030000 — Sphere Wizard of Oz: full ignore + data archive
--
-- Lane:     A1
-- Touches:  events (129 past rows -> state='ignored'); new schema archive with
--           5 cold tables; moves all Sphere-collected rows out of the hot tables
--           (listings_snapshots, section_metrics, event_metrics, zone_metrics,
--           event_listing_snapshot_daily).
-- Pre-reqs: 20260702014500 (future-event ignore + SG SKIP + discovery deactivate).
--
-- WHY (operator 2026-07-02: "remove wizard of oz from terminal page, and
-- archive data"):
--   20260702014500 ignored the 453 FUTURE Sphere Wizard events (performer
--   123021) so the pollers drop them, but (a) 129 PAST events still had
--   state != 'ignored', and (b) ~9.85M rows of already-collected data still sat
--   in the hot serving tables, feeding latest_event_metrics and any
--   events-table-driven terminal list (search, /api/portfolio). This migration
--   completes the removal wholesale:
--     1) ALL 582 Sphere Wizard events -> state='ignored' (past ones included).
--     2) New `archive` schema (NOT exposed via PostgREST — only public is in
--        the exposed-schemas list, so archived data has no API surface) with
--        index-free cold copies:
--          archive.sphere_listings_snapshots             8,823,403 rows
--          archive.sphere_section_metrics                  920,127 rows
--          archive.sphere_event_metrics                     53,593 rows
--          archive.sphere_zone_metrics                       2,874 rows
--          archive.sphere_event_listing_snapshot_daily      49,918 rows
--     3) Atomic drain moves (DELETE ... RETURNING -> INSERT) executed in
--        bounded event-batches (15-60 events, SET statement_timeout 120-150s
--        per batch) to stay far under the wedge thresholds. Verified: archive
--        counts match the pre-move source counts exactly; 0 Sphere rows remain
--        in any hot table; latest_event_metrics carries 0 Sphere rows.
--   Data is ARCHIVED, not deleted — retrievable from archive.* if ever needed.
--
--   Paired code change (same PR): core/search.py + routers/broker.py portfolio
--   now filter state='ignored' events client-side (PostgREST .neq() would also
--   drop NULL-state rows, so the filter is in Python).
--
-- Idempotent: re-run moves 0 rows (drain style); UPDATE/CREATE are guarded.
-- Already applied to prod · via MCP 2026-07-02 (batched; see WHY for batching)
-- ============================================================================

UPDATE events SET state='ignored'
WHERE primary_performer_id = 123021 AND coalesce(state,'') <> 'ignored';

CREATE SCHEMA IF NOT EXISTS archive;
CREATE TABLE IF NOT EXISTS archive.sphere_listings_snapshots  (LIKE public.listings_snapshots  INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS archive.sphere_section_metrics     (LIKE public.section_metrics     INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS archive.sphere_event_metrics       (LIKE public.event_metrics       INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS archive.sphere_zone_metrics        (LIKE public.zone_metrics        INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS archive.sphere_event_listing_snapshot_daily (LIKE public.event_listing_snapshot_daily INCLUDING DEFAULTS);

-- Drain moves. In prod these ran as bounded event-batches (LIMIT 15-60 per
-- statement, repeated until 0 remained) to keep each statement seconds-long;
-- the single-statement form below is the idempotent record — on a fresh
-- environment it does the whole move, on prod it moves 0 rows.
WITH sphere AS (SELECT id FROM events WHERE primary_performer_id = 123021),
mz AS (DELETE FROM zone_metrics WHERE event_id IN (SELECT id FROM sphere) RETURNING *)
INSERT INTO archive.sphere_zone_metrics SELECT * FROM mz;

WITH sphere AS (SELECT id FROM events WHERE primary_performer_id = 123021),
me AS (DELETE FROM event_metrics WHERE event_id IN (SELECT id FROM sphere) RETURNING *)
INSERT INTO archive.sphere_event_metrics SELECT * FROM me;

WITH sphere AS (SELECT id FROM events WHERE primary_performer_id = 123021),
md AS (DELETE FROM event_listing_snapshot_daily WHERE event_id IN (SELECT id FROM sphere) RETURNING *)
INSERT INTO archive.sphere_event_listing_snapshot_daily SELECT * FROM md;

WITH sphere AS (SELECT id FROM events WHERE primary_performer_id = 123021),
ms AS (DELETE FROM section_metrics WHERE event_id IN (SELECT id FROM sphere) RETURNING *)
INSERT INTO archive.sphere_section_metrics SELECT * FROM ms;

WITH sphere AS (SELECT id FROM events WHERE primary_performer_id = 123021),
ml AS (DELETE FROM listings_snapshots WHERE event_id IN (SELECT id FROM sphere) RETURNING *)
INSERT INTO archive.sphere_listings_snapshots SELECT * FROM ml;
