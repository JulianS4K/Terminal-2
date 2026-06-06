-- Migration 20260606160000 · lane:D0 · writes: cross_source_venue_map (sg alias)
--   · then operationally re-runs matcher + backfill_aq_maps()
--
-- ## Already applied to prod · Applied via MCP 2026-06-06 (operator-authorized)
--
-- Arrowhead Stadium naming-rights alias. SeatGeek lists Kansas City Chiefs games
-- at "GEHA Field at Arrowhead Stadium"; TEvo venue 67 is "Arrowhead Stadium".
-- Same-building naming-rights difference (cf. 20260606130000). Surfaced as the
-- only real twin in a fuzzy concert/game sweep -- the rest of the remaining
-- unmapped is an SG catalog-coverage gap (SG events not in sg_events_canonical),
-- not a mapping/alias gap.

update public.cross_source_venue_map
  set sg_aliases = sg_aliases || to_jsonb('GEHA Field at Arrowhead Stadium'::text), updated_at = now()
  where tevo_venue_id = 67 and not (sg_aliases ? 'GEHA Field at Arrowhead Stadium');

-- select public.auto_match_sg_canonical_v3();  -- linked the Sep 14 Broncos@Chiefs game
-- select public.backfill_aq_maps();            -- propagated to hub
