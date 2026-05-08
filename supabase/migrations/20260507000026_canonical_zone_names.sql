-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod as 20260507000019; RENUMBERED to 26 here because
-- code's mig 19 (drop_redundant_unique_constraints) used that version concurrently.
--
-- SQL classifier mirroring the TS classifyZone in chat fn so placeholder zone
-- names stay aligned with what the chat fn produces at runtime.

CREATE OR REPLACE FUNCTION classify_zone_canonical(p_section text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  WITH s AS (SELECT lower(regexp_replace(coalesce(p_section, ''), '\s+', '', 'g')) AS x)
  SELECT CASE
    WHEN s.x = '' THEN 'Special'
    WHEN s.x ~ '(courtside|^crt|^cside|^floor|^fl\d|^ga$|^pit$)' THEN 'Floor / Pit / GA'
    WHEN s.x ~ '(^vip|^vip\d|vipsuite|premium|hospitality|clublounge|skybox)' THEN 'Premium / VIP'
    WHEN s.x ~ '(^box|box$)' THEN 'Box'
    WHEN s.x ~ 'loge' THEN 'Loge'
    WHEN s.x ~ '(balcony|^bal\d|^bal$)' THEN 'Balcony'
    WHEN s.x ~ '(grandstand|^gs)' THEN 'Grandstand'
    WHEN s.x ~ 'bleach' THEN 'Bleachers'
    WHEN s.x ~ '(lawn|terrace)' THEN 'Lawn / Terrace'
    WHEN (regexp_match(p_section, '(\d+)'))[1] IS NOT NULL THEN
      CASE
        WHEN (regexp_match(p_section, '(\d+)'))[1]::int BETWEEN 1   AND 199 THEN 'Lower (100s)'
        WHEN (regexp_match(p_section, '(\d+)'))[1]::int BETWEEN 200 AND 299 THEN 'Club (200s)'
        WHEN (regexp_match(p_section, '(\d+)'))[1]::int BETWEEN 300 AND 399 THEN 'Upper (300s)'
        WHEN (regexp_match(p_section, '(\d+)'))[1]::int BETWEEN 400 AND 499 THEN 'Upper (400s)'
        WHEN (regexp_match(p_section, '(\d+)'))[1]::int >= 500             THEN 'Upper (500s+)'
        ELSE 'Special'
      END
    ELSE 'Special'
  END FROM s;
$$;

CREATE OR REPLACE FUNCTION generate_system_placeholder_zones(p_performer_id bigint, p_venue_id bigint)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE
  v_inserted int := 0;
  v_zone_id bigint;
  r record;
BEGIN
  IF EXISTS (SELECT 1 FROM performer_zones WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND source = 'curated') THEN
    RETURN 0;
  END IF;
  DELETE FROM performer_zone_rules WHERE zone_id IN (
    SELECT id FROM performer_zones WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND source = 'system_placeholder'
  );
  DELETE FROM performer_zones WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND source = 'system_placeholder';

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

SELECT bulk_generate_system_placeholder_zones();
