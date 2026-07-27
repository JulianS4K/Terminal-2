-- Migration 20260702155000 · lane:D0 (author) → A1 (apply) · writes(DDL):get_wc_seatmap_donor · reads:aq_event_map, aq_venue_map, events, seatmap_manifest, venue_assets · pre:20260616180000_wc_all_platforms · auth:operator-requested 2026-07-02 ("if no evo event id, why not use a different event that has the same map and redirect")
--
-- ## Applied to prod 2026-07-02 via MCP apply_migration (operator-directed). Idempotent.
--
-- Seat maps are a (venue_id, configuration_id) asset, NOT an event asset — the
-- terminal renders them via Tevomaps.SeatmapFactory({venueId, configurationId})
-- and uses the event id ONLY to look those two ids up in `events`. World Cup
-- matches are SG-native (no TEvo event id -> no venue/config of their own), so
-- they can't self-resolve a map. This resolver borrows a DONOR
-- (venue_id, configuration_id) from a real event at the SAME venue whose config
-- already has a rendered map (seatmap_manifest.has_map=true): resolve the match's
-- venue through the AQ hub (aq_event_map.venue_short_id -> aq_venue_map.tevo_venue_id),
-- then pick that venue's most-used mapped config (its primary bowl), most-recent
-- as tiebreak. NOTE: the donor config is often a football layout — the map is
-- venue-accurate but soccer sections can differ. Consumed by the terminal SG-mode
-- event page (static/terminal/event.js loadWcSeatmapDonor). Email-gated, anon revoked.
CREATE OR REPLACE FUNCTION public.get_wc_seatmap_donor(p_sg_event_id bigint)
RETURNS TABLE(
  venue_id            bigint,
  configuration_id    integer,
  configuration_name  text,
  donor_event_id      bigint,
  venue_name          text,
  donor_events_count  integer,
  note                text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email', '');
  v_tevo_venue bigint;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;

  SELECT vm.tevo_venue_id INTO v_tevo_venue
  FROM public.aq_event_map a
  JOIN public.aq_venue_map vm ON vm.venue_short_id = a.venue_short_id
  WHERE a.sg_event_id = p_sg_event_id AND vm.tevo_venue_id IS NOT NULL
  LIMIT 1;
  IF v_tevo_venue IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT e.venue_id,
         e.configuration_id,
         (array_agg(e.configuration_name ORDER BY e.occurs_at_local DESC))[1],
         (array_agg(e.id                 ORDER BY e.occurs_at_local DESC))[1],
         (SELECT va.venue_name FROM public.venue_assets va WHERE va.tevo_venue_id = v_tevo_venue LIMIT 1),
         count(*)::int,
         'donor config from another event at the same venue; map is venue-level (soccer sections may differ from this layout)'::text
  FROM public.events e
  JOIN public.seatmap_manifest sm
    ON sm.venue_id = e.venue_id AND sm.configuration_id = e.configuration_id AND sm.has_map = true
  WHERE e.venue_id = v_tevo_venue AND e.configuration_id IS NOT NULL
  GROUP BY e.venue_id, e.configuration_id
  ORDER BY count(*) DESC, max(e.occurs_at_local) DESC
  LIMIT 1;
END $func$;

REVOKE ALL ON FUNCTION public.get_wc_seatmap_donor(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_wc_seatmap_donor(bigint) TO authenticated;
