-- Migration 20260811272000 · lane:D0 · operator-directed 2026-08-11
--   ("hard default to the manual zones"): the single curated-zone resolver used by both the
--   baseline rebuild and (next) the scanner, so a GoTickets "Lower 127" and a SeatGeek
--   "field box 127" land in the SAME manual zone.
--
--   writes: gt_curated_zone_id(bigint,bigint,text) [fn].
--
-- WHY. performer_zone_rules match section ranges numerically (section_in_range), but source
-- section strings are word+number ("Lower 127"), which the numeric path can't match raw. This
-- helper extracts the section number first, then resolves it against the performer+venue's
-- CURATED rules (performer_zones.source='curated'). Measured GT-listing resolution ≈ 88% on
-- well-covered venues (misses: ~7% no-number GA/floor/SRO, ~4% numeric rule-gaps; some venues
-- lower where GT's section format diverges from the curated ranges). STABLE, so it inlines in
-- the scanner's set-based query.
--
-- ROLLBACK: DROP FUNCTION public.gt_curated_zone_id(bigint,bigint,text);

CREATE OR REPLACE FUNCTION public.gt_curated_zone_id(p_performer_id bigint, p_venue_id bigint, p_section text)
RETURNS bigint LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $$
  SELECT pzr.zone_id
  FROM public.performer_zones pz
  JOIN public.performer_zone_rules pzr ON pzr.zone_id = pz.id
  WHERE pz.performer_id = p_performer_id AND pz.venue_id = p_venue_id AND pz.source='curated'
    AND public.section_in_range(coalesce((regexp_match(p_section,'(\d{2,4})'))[1], p_section),
                                pzr.section_from, pzr.section_to)
  ORDER BY pzr.id LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION public.gt_curated_zone_id(bigint,bigint,text) TO authenticated, service_role;
COMMENT ON FUNCTION public.gt_curated_zone_id(bigint,bigint,text) IS
  'Resolve (performer, venue, section) to its curated manual zone_id (performer_zones.source=curated) via the extracted section number. Shared by the realized-sale baseline + deals scanner so all sources map to the same manual zone. D0 mig 20260811272000.';