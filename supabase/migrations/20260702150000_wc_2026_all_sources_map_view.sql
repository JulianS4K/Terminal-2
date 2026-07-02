-- Migration 20260702150000 · lane:D0 (author) → A1 (apply) · writes:v_world_cup_2026_all_sources (view) · reads:world_cup_2026, aq_event_map, ticketsdata_event_xref · pre:20260616180000_wc_all_platforms · auth:operator-requested 2026-07-02 ("map them to all sources using tickets data")
--
-- D0 — one queryable surface that shows every 2026 FIFA World Cup match against
-- its id on EVERY source. The cross-source ids already exist: the TicketsData
-- /match resolver (sg_match_map_tick, migration 20260619163000) walks the
-- SeatGeek-anchored aq_event_map rows and COALESCE-fills sh/vivid/tm ids, and the
-- WC-specific seed (migration 20260616180000) hydrated Ticketmaster from the hub.
-- But that mapping is scattered across three places — the schedule lives in
-- world_cup_2026, the SG/TEvo/SH/VD/TM ids in aq_event_map, and the GameTime id
-- only in ticketsdata_event_xref. This view stitches them into one row per match
-- so "is match N mapped to StubHub / Vivid / Ticketmaster / GameTime / TEvo?" is a
-- single SELECT, and the gaps (unmapped source per match) are visible at a glance.
--
-- WHY A VIEW (not more columns on world_cup_2026): the ids in aq_event_map are
-- kept live by the /match cron; a view reflects the current mapping on every read
-- with zero write + zero staleness, whereas frozen columns would drift until the
-- next refresh_world_cup_2026() run. The static tournament structure (match #,
-- stage, teams, venue) is read straight from world_cup_2026.
--
-- SECURITY: backend-only, matching the underlying world_cup_2026 (RLS on, no
-- policy => service-role only). security_invoker=true makes the view inherit that
-- exact posture — the service role bypasses RLS and reads it; anon/authenticated
-- are denied by the base-table RLS. anon/public are also REVOKE'd for defense in
-- depth. No pricing/wholesale fields are exposed, only public schedule + ids.
--
-- Idempotent: CREATE OR REPLACE VIEW. Read-only (no data mutation).

CREATE OR REPLACE VIEW public.v_world_cup_2026_all_sources
WITH (security_invoker = true) AS
WITH gt AS (
  -- GameTime id lives only in the TD xref (no aq_event_map column for it)
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
  -- one id column per source
  w.sg_event_id,
  w.tevo_event_id,
  a.sh_event_id      AS stubhub_event_id,
  a.vivid_event_id   AS vivid_event_id,
  a.tm_event_id      AS ticketmaster_event_id,
  g.gt_event_id      AS gametime_event_id,
  -- rolled-up mapping status: which sources this match is resolved to, and how many
  ARRAY_REMOVE(ARRAY[
    CASE WHEN w.sg_event_id     IS NOT NULL THEN 'SeatGeek'     END,
    CASE WHEN w.tevo_event_id   IS NOT NULL THEN 'TEvo'         END,
    CASE WHEN a.sh_event_id     IS NOT NULL THEN 'StubHub'      END,
    CASE WHEN a.vivid_event_id  IS NOT NULL THEN 'VividSeats'   END,
    CASE WHEN a.tm_event_id     IS NOT NULL THEN 'Ticketmaster' END,
    CASE WHEN g.gt_event_id     IS NOT NULL THEN 'GameTime'     END
  ], NULL) AS sources_mapped,
  ( (w.sg_event_id     IS NOT NULL)::int
  + (w.tevo_event_id   IS NOT NULL)::int
  + (a.sh_event_id     IS NOT NULL)::int
  + (a.vivid_event_id  IS NOT NULL)::int
  + (a.tm_event_id     IS NOT NULL)::int
  + (g.gt_event_id     IS NOT NULL)::int ) AS sources_mapped_count,
  -- ownership snapshot carried through from world_cup_2026 (as of its last refresh)
  w.we_own,
  w.owned_tickets_count,
  w.refreshed_at
FROM public.world_cup_2026 w
LEFT JOIN public.aq_event_map a ON a.sg_event_id = w.sg_event_id
LEFT JOIN gt g                  ON g.aq_short_event_id = a.aq_short_event_id;

COMMENT ON VIEW public.v_world_cup_2026_all_sources IS
  'One row per 2026 FIFA World Cup match with its id on every source (SeatGeek/TEvo/StubHub/VividSeats/Ticketmaster/GameTime), resolved through the AQ hub (aq_event_map) + TD xref (GameTime). sources_mapped/_count expose per-match cross-source coverage. Backend-only (security_invoker inherits world_cup_2026 RLS). D0 2026-07-02.';

REVOKE ALL ON public.v_world_cup_2026_all_sources FROM anon, public;
