-- Migration 20260702150000 · lane:D0 (author) → A1 (apply) · writes:v_world_cup_2026_all_sources (view) · reads:world_cup_2026, aq_event_map, ticketsdata_event_xref, aq_venue_map, events, seatmap_manifest · pre:20260616180000_wc_all_platforms · auth:operator-requested 2026-07-02 ("map them to all sources"; "link seat map and seatdata sales")
--
-- D0 — one queryable surface: every 2026 FIFA World Cup match against its id on
-- EVERY source, plus its seat-map + SeatData linkage. The market ids already
-- exist (the TicketsData /match resolver COALESCE-fills sh/vivid/tm onto the AQ
-- hub; the WC seed hydrated Ticketmaster; GameTime lives in the TD xref). This
-- view stitches the scattered pieces into one row per match so per-match
-- cross-source coverage + gaps are a single SELECT.
--
-- Two source families beyond the ticketing markets:
--   • SeatData sales — keyed on tevo_event_id (aq_event_map.sd_event_id). WC
--     matches are SG-native (almost none have a TEvo id), so this is populated
--     only for the handful of matches TEvo carries; exposed as seatdata_event_id.
--   • Seat map — a (venue_id, configuration_id) asset, NOT an event asset. WC
--     matches have no TEvo event/config of their own, so seatmap_available is
--     derived by borrowing a DONOR config: does an event at the same venue
--     (aq_venue_map → tevo_venue_id) already have a rendered map
--     (seatmap_manifest.has_map)? get_wc_seatmap_donor() resolves the concrete
--     donor at request time; here we surface venue + best donor config + a flag.
--
-- WHY A VIEW: the ids in aq_event_map are kept live by the /match cron; a view
-- reflects the current mapping on every read with zero write + zero staleness.
--
-- SECURITY: backend-only, matching world_cup_2026 (RLS on, no policy => service
-- role only). security_invoker=true inherits that posture; anon/public REVOKE'd
-- for defense in depth. No pricing/wholesale fields — only schedule + ids.
--
-- Idempotent: CREATE OR REPLACE VIEW. Read-only (no data mutation).

CREATE OR REPLACE VIEW public.v_world_cup_2026_all_sources
WITH (security_invoker = true) AS
WITH gt AS (
  SELECT aq_short_event_id, max(event_id) FILTER (WHERE platform = 'GT') AS gt_event_id
  FROM public.ticketsdata_event_xref
  GROUP BY aq_short_event_id
)
SELECT
  w.match_number,
  w.stage,
  w.group_label,
  w.match_label,
  w.event_date,
  w.event_datetime,
  w.venue_name,
  w.venue_city,
  w.venue_state,
  a.aq_short_event_id,
  -- one id column per ticketing source
  w.sg_event_id,
  w.tevo_event_id,
  a.sh_event_id      AS stubhub_event_id,
  a.vivid_event_id   AS vivid_event_id,
  a.tm_event_id      AS ticketmaster_event_id,
  g.gt_event_id      AS gametime_event_id,
  -- SeatData (sales comps) — only where the match has a TEvo id to key on
  a.sd_event_id      AS seatdata_event_id,
  -- Seat map (venue-level, borrowed donor config)
  sm_donor.tevo_venue_id                          AS seatmap_venue_id,
  sm_donor.donor_config                           AS seatmap_donor_config,
  (sm_donor.donor_config IS NOT NULL)             AS seatmap_available,
  -- rolled-up coverage across every source
  ARRAY_REMOVE(ARRAY[
    CASE WHEN w.sg_event_id      IS NOT NULL THEN 'SeatGeek'     END,
    CASE WHEN w.tevo_event_id    IS NOT NULL THEN 'TEvo'         END,
    CASE WHEN a.sh_event_id      IS NOT NULL THEN 'StubHub'      END,
    CASE WHEN a.vivid_event_id   IS NOT NULL THEN 'VividSeats'   END,
    CASE WHEN a.tm_event_id      IS NOT NULL THEN 'Ticketmaster' END,
    CASE WHEN g.gt_event_id      IS NOT NULL THEN 'GameTime'     END,
    CASE WHEN a.sd_event_id      IS NOT NULL THEN 'SeatData'     END,
    CASE WHEN sm_donor.donor_config IS NOT NULL THEN 'SeatMap'   END
  ], NULL) AS sources_mapped,
  ( (w.sg_event_id      IS NOT NULL)::int
  + (w.tevo_event_id    IS NOT NULL)::int
  + (a.sh_event_id      IS NOT NULL)::int
  + (a.vivid_event_id   IS NOT NULL)::int
  + (a.tm_event_id      IS NOT NULL)::int
  + (g.gt_event_id      IS NOT NULL)::int
  + (a.sd_event_id      IS NOT NULL)::int
  + (sm_donor.donor_config IS NOT NULL)::int ) AS sources_mapped_count,
  w.we_own,
  w.owned_tickets_count,
  w.refreshed_at
FROM public.world_cup_2026 w
LEFT JOIN public.aq_event_map a ON a.sg_event_id = w.sg_event_id
LEFT JOIN gt g                  ON g.aq_short_event_id = a.aq_short_event_id
-- venue → tevo_venue_id → best donor config with a rendered map (one row, no fan-out)
LEFT JOIN LATERAL (
  SELECT vm.tevo_venue_id,
         (SELECT e.configuration_id
            FROM public.events e
            JOIN public.seatmap_manifest sm
              ON sm.venue_id = e.venue_id AND sm.configuration_id = e.configuration_id AND sm.has_map = true
           WHERE e.venue_id = vm.tevo_venue_id AND e.configuration_id IS NOT NULL
           GROUP BY e.configuration_id
           ORDER BY count(*) DESC, max(e.occurs_at_local) DESC
           LIMIT 1) AS donor_config
  FROM public.aq_venue_map vm
  WHERE vm.venue_short_id = a.venue_short_id
  LIMIT 1
) sm_donor ON true;

COMMENT ON VIEW public.v_world_cup_2026_all_sources IS
  'One row per 2026 FIFA World Cup match with its id on every source (SeatGeek/TEvo/StubHub/VividSeats/Ticketmaster/GameTime) + SeatData (tevo-keyed) + seat-map donor availability (borrowed venue config). sources_mapped/_count expose per-match coverage. Backend-only (security_invoker inherits world_cup_2026 RLS). D0 2026-07-02.';

REVOKE ALL ON public.v_world_cup_2026_all_sources FROM anon, public;
