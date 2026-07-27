-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod as 20260507000020; RENUMBERED to 27 here because
-- code's mig 20 (drop_team_xref) used that version concurrently.
--
-- Hybrid zone model: curated + system_placeholder always coexist for the
-- same (performer, venue). Curated wins on overlap because matchCuratedZone
-- walks performer_zones in display_order ASC and returns the first match.
-- Curated zones are typically given display_order 1-30; placeholders use
-- 5-99 derived from tier; so when both define a rule covering the same
-- section, the curated zone is matched first.

CREATE OR REPLACE FUNCTION generate_system_placeholder_zones(p_performer_id bigint, p_venue_id bigint)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE
  v_inserted int := 0;
  v_zone_id bigint;
  r record;
BEGIN
  -- Wipe ONLY the prior placeholder set so re-runs are idempotent.
  -- Curated zones for this pair are NEVER touched.
  DELETE FROM performer_zone_rules WHERE zone_id IN (
    SELECT id FROM performer_zones
    WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND source = 'system_placeholder'
  );
  DELETE FROM performer_zones
  WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND source = 'system_placeholder';

  FOR r IN
    WITH events_for_pair AS (
      SELECT id FROM events WHERE primary_performer_id = p_performer_id AND venue_id = p_venue_id
    ),
    latest_per_event AS (
      SELECT event_id, max(captured_at) AS captured_at
      FROM listings_snapshots WHERE event_id IN (SELECT id FROM events_for_pair)
      GROUP BY event_id
    ),
    sections AS (
      SELECT DISTINCT l.section
      FROM listings_snapshots l JOIN latest_per_event lpe USING (event_id, captured_at)
      WHERE l.section IS NOT NULL AND l.is_ancillary = false
    ),
    zoned AS (SELECT section, classify_zone_canonical(section) AS zone FROM sections),
    zones AS (
      SELECT zone, array_agg(DISTINCT section ORDER BY section) AS sections,
             min(CASE zone
               WHEN 'Floor / Pit / GA' THEN 1
               WHEN 'Premium / VIP'    THEN 2
               WHEN 'Box'              THEN 3
               WHEN 'Loge'             THEN 4
               WHEN 'Lower (100s)'     THEN 5
               WHEN 'Club (200s)'      THEN 6
               WHEN 'Upper (300s)'     THEN 7
               WHEN 'Upper (400s)'     THEN 8
               WHEN 'Upper (500s+)'    THEN 9
               WHEN 'Balcony'          THEN 10
               WHEN 'Grandstand'       THEN 11
               WHEN 'Bleachers'        THEN 12
               WHEN 'Lawn / Terrace'   THEN 13
               ELSE 99 END) AS display_order
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

SELECT generate_system_placeholder_zones(16303, 896);
SELECT bulk_generate_system_placeholder_zones();

COMMENT ON FUNCTION generate_system_placeholder_zones IS
  'Generates system_placeholder zones for a (performer, venue) by mining listings_snapshots. NEVER skips even if curated zones exist — curated and placeholder coexist. Curated wins on overlap via display_order priority (curated typically 1-30 vs placeholder 5-99). Placeholders cover sections curated rules miss.';
