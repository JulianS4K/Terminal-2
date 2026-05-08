-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod as 20260507000018; RENUMBERED to 25 here because
-- code's mig 18 (espn_fix_sport_slug) used that version concurrently. Both
-- versions ran in prod (different timestamps); only this renumbering matters
-- for fresh-environment replay from git.
--
-- System-placeholder zones: data-driven defaults per (performer, venue) so the
-- chatbot's curated-zone lookup gets venue-aware names everywhere, not just
-- where we've manually curated. Mined from listings_snapshots.

ALTER TABLE performer_zones
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'curated' CHECK (source IN ('curated','system_placeholder'));

CREATE INDEX IF NOT EXISTS performer_zones_source_idx ON performer_zones (source);

CREATE OR REPLACE FUNCTION generate_system_placeholder_zones(p_performer_id bigint, p_venue_id bigint)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE
  v_inserted int := 0;
  v_zone_id bigint;
  r record;
BEGIN
  IF EXISTS (
    SELECT 1 FROM performer_zones
    WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND source = 'curated'
  ) THEN
    RETURN 0;
  END IF;

  DELETE FROM performer_zone_rules WHERE zone_id IN (
    SELECT id FROM performer_zones
    WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND source = 'system_placeholder'
  );
  DELETE FROM performer_zones
  WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND source = 'system_placeholder';

  FOR r IN
    WITH events_for_pair AS (
      SELECT id FROM events
      WHERE primary_performer_id = p_performer_id AND venue_id = p_venue_id
    ),
    latest_per_event AS (
      SELECT event_id, max(captured_at) AS captured_at
      FROM listings_snapshots
      WHERE event_id IN (SELECT id FROM events_for_pair)
      GROUP BY event_id
    ),
    sections AS (
      SELECT DISTINCT l.section
      FROM listings_snapshots l
      JOIN latest_per_event lpe USING (event_id, captured_at)
      WHERE l.section IS NOT NULL AND l.is_ancillary = false
    ),
    zoned AS (
      SELECT section, COALESCE(derive_zone_fallback(section, NULL), 'Other') AS zone
      FROM sections
    ),
    zones AS (
      SELECT zone, array_agg(DISTINCT section ORDER BY section) AS sections,
             min(CASE
               WHEN zone ILIKE '%floor%' OR zone ILIKE '%pit%' OR zone ILIKE '%ga%' THEN 1
               WHEN zone ILIKE '%vip%' OR zone ILIKE '%premium%' THEN 2
               WHEN zone ILIKE '%100%' OR zone ILIKE '%lower%' THEN 5
               WHEN zone ILIKE '%200%' OR zone ILIKE '%club%' THEN 6
               WHEN zone ILIKE '%300%' THEN 7
               WHEN zone ILIKE '%400%' THEN 8
               WHEN zone ILIKE '%500%' THEN 9
               WHEN zone ILIKE '%balcony%' THEN 10
               ELSE 99
             END) AS display_order
      FROM zoned GROUP BY zone
    )
    SELECT zone, sections, display_order FROM zones ORDER BY display_order
  LOOP
    INSERT INTO performer_zones (performer_id, venue_id, name, display_order, source)
    VALUES (p_performer_id, p_venue_id, r.zone, r.display_order, 'system_placeholder')
    RETURNING id INTO v_zone_id;
    INSERT INTO performer_zone_rules (zone_id, section_from, section_to, row_from, row_to)
    SELECT v_zone_id, s, s, NULL, NULL FROM unnest(r.sections) AS s;
    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN v_inserted;
END
$fn$;

CREATE OR REPLACE FUNCTION bulk_generate_system_placeholder_zones()
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  r record;
  pair_count int := 0;
  zone_count int := 0;
  this_inserted int;
BEGIN
  FOR r IN
    SELECT DISTINCT e.primary_performer_id AS performer_id, e.venue_id
    FROM events e
    JOIN listings_snapshots l ON l.event_id = e.id
    WHERE e.primary_performer_id IS NOT NULL AND e.venue_id IS NOT NULL
  LOOP
    this_inserted := generate_system_placeholder_zones(r.performer_id, r.venue_id);
    IF this_inserted > 0 THEN
      pair_count := pair_count + 1;
      zone_count := zone_count + this_inserted;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('pairs_processed', pair_count, 'zones_inserted', zone_count);
END
$fn$;

COMMENT ON FUNCTION generate_system_placeholder_zones IS
  'Mines listings_snapshots for distinct sections at a (performer, venue) tuple and writes performer_zones + performer_zone_rules with source=system_placeholder. Skips when curated zones already exist. Idempotent.';
COMMENT ON FUNCTION bulk_generate_system_placeholder_zones IS
  'One-shot: generates system_placeholder zones for every (performer, venue) tuple that has snapshot data and no curated zones.';
