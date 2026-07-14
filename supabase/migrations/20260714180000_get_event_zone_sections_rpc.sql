-- Migration 20260714180000 · lane:D0 (author) → applier (apply) · writes:get_event_zone_sections(bigint) [fn] · reads:events,v_section_to_curated_zone,performer_zones,venue_section_map · pre:v_section_to_curated_zone + section_in_range (mig 20260509240000 / curated-zone import 20260707120000), venue_section_map (mig 20260622150030), get_event_zones sibling (mig 20260708180030) · auth:OPERATOR-APPROVED read-only SECDEF (email-gated @s4kent.com; grants authenticated only, no anon)
--
-- WHY. The D0 terminal seat-map tab has a zone quick-select row: one click
-- selects every venue-map polygon in a curated pricing zone (L1 / U1 / FO / …),
-- highlighting them on the map and filtering the listings below. The zone→section
-- membership lives in the CURATED import (performer_zones + performer_zone_rules,
-- resolved per event by v_section_to_curated_zone) — all RLS-locked, so the
-- browser (authenticated @s4kent.com JWT) can't read it directly. The sibling
-- get_event_zones RPC exposes only zone NAMES + price metrics, not the section
-- membership needed to drive map selection.
--
-- This SECDEF read RPC bridges the two RLS-locked sources the front-end needs:
--   * v_section_to_curated_zone → each curated zone's section ranges for the event
--     (via the event's home performer + venue), joined to performer_zones for the
--     display_order the picker sorts by;
--   * venue_section_map → the section_raw → seatmap_key (map polygon) crosswalk,
--     config-aware (event's configuration bucket, falling back to the union bucket
--     0 like get_event_section_map).
-- A zone COVERS a polygon when section_in_range(section_raw, section_from,
-- section_to) — the same range predicate v_listing_zone_auto uses. Output is one
-- object per zone with the DISTINCT lower-cased polygon keys it covers (the exact
-- identifiers the map draws + selects by), ordered by display_order.
--
-- Read-only (SELECT only) + email-gated, mirroring get_event_zones /
-- get_event_section_map. ROLLBACK: DROP FUNCTION get_event_zone_sections(bigint).

CREATE OR REPLACE FUNCTION public.get_event_zone_sections(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email  text;
  v_venue  bigint;
  v_cfg    integer;
  v_use    integer;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT e.venue_id, e.configuration_id INTO v_venue, v_cfg
  FROM public.events e WHERE e.id = p_event_id;
  IF v_venue IS NULL THEN
    RETURN jsonb_build_object('zones', '[]'::jsonb, 'count', 0, 'source', NULL);
  END IF;

  -- Config-aware crosswalk bucket: prefer the event's configuration, else the
  -- union bucket (configuration_id = 0) — same resolution as get_event_section_map.
  v_use := v_cfg;
  IF v_use IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.venue_section_map m
        WHERE m.tevo_venue_id = v_venue AND m.configuration_id = v_use) THEN
    v_use := 0;
  END IF;

  WITH zr AS (
    SELECT z.zone_id, z.zone_name, pz.display_order, z.section_from, z.section_to
    FROM public.v_section_to_curated_zone z
    JOIN public.performer_zones pz ON pz.id = z.zone_id
    WHERE z.tevo_event_id = p_event_id
  ),
  smap AS (
    SELECT DISTINCT m.section_raw, m.seatmap_key
    FROM public.venue_section_map m
    WHERE m.tevo_venue_id = v_venue
      AND m.configuration_id = v_use
      AND m.seatmap_key IS NOT NULL
  ),
  zone_keys AS (
    SELECT r.zone_id,
           min(r.zone_name)      AS zone_name,
           min(r.display_order)  AS display_order,
           array_agg(DISTINCT s.seatmap_key) AS seatmap_keys
    FROM zr r
    JOIN smap s ON public.section_in_range(s.section_raw, r.section_from, r.section_to)
    GROUP BY r.zone_id
  )
  SELECT jsonb_build_object(
    'zones', coalesce(jsonb_agg(jsonb_build_object(
        'zone_id',       zk.zone_id,
        'zone_name',     zk.zone_name,
        'display_order', zk.display_order,
        'seatmap_keys',  to_jsonb(zk.seatmap_keys)
      ) ORDER BY zk.display_order NULLS LAST, zk.zone_name), '[]'::jsonb),
    'count',  count(*),
    'source', 'curated'
  ) INTO v_result
  FROM zone_keys zk;

  RETURN coalesce(v_result, jsonb_build_object('zones', '[]'::jsonb, 'count', 0, 'source', 'curated'));
END;
$func$;

REVOKE ALL ON FUNCTION public.get_event_zone_sections(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_event_zone_sections(bigint) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_event_zone_sections(bigint) TO authenticated;

COMMENT ON FUNCTION public.get_event_zone_sections(bigint) IS
  'D0 seat-map zone quick-select: per-event curated zones (performer_zones/v_section_to_curated_zone) resolved to the map-polygon keys (venue_section_map, config-aware) each covers, via section_in_range. Returns {zones:[{zone_id,zone_name,display_order,seatmap_keys[]}],count,source}. Email-gated SECDEF, authenticated-only.';
