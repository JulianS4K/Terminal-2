-- Migration 20260703141100 · lane:A1 (data plane — SeatGeek event-mapping allowlist)
--   writes on run: td_sg_performers (INSERT performers of unmapped events at target venues)
--   reads: events, aq_event_map, event_xref
--   spends: nothing at apply; daily td_sg_discover then /events-searches each (1 credit, budget-gated)
--   pre: 20260703141000 (league-performer enrollment)
--   auth: operator directive 2026-07-03 (julian@s4kent.com — "keep discovering and matching")
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- Companion to mig 20260703141000: extends SeatGeek-discovery enrollment from the
-- league buckets to the VENUE buckets in the expanded target set (mig 20260703140000)
-- — the concert-venue allowlist, all NFL/NBA venues, and MSG (venue 896). Enrolls the
-- distinct performers behind unmapped upcoming events at those venues (no sh/vivid and
-- no sg_event_id) so discovery gives them a SeatGeek anchor → auto_match → hub → the
-- soonest-first sg_match_map_tick /match fills their StubHub/Vivid ids. Same slug
-- construction + throughput caveats as mig 20260703141000.
-- ─────────────────────────────────────────────────────────────────────────────

WITH tgt_venues AS (
  SELECT unnest(ARRAY[1290,520,1366,996,8000,4603,33,5118,103,33737,2407,2839,7425,38485,228,896]) AS venue_id
  UNION
  SELECT DISTINCT e.venue_id
  FROM public.event_xref ex JOIN public.events e ON e.id = ex.tevo_event_id
  WHERE ex.espn_league IN ('NFL','NBA') AND e.venue_id IS NOT NULL
)
INSERT INTO public.td_sg_performers (tevo_performer_id, performer_name, performer_url, active)
SELECT DISTINCT ON (e.primary_performer_id) e.primary_performer_id, e.primary_performer_name,
  'https://seatgeek.com/'||trim(both '-' from regexp_replace(lower(e.primary_performer_name),'[^a-z0-9]+','-','g'))||'-tickets',
  true
FROM public.events e
JOIN public.aq_event_map aem ON aem.tevo_event_id = e.id
WHERE e.venue_id IN (SELECT venue_id FROM tgt_venues)
  AND aem.event_date > now()
  AND aem.event_name NOT ILIKE '%parking%'
  AND aem.sh_event_id IS NULL AND aem.vivid_event_id IS NULL AND aem.sg_event_id IS NULL
  AND e.primary_performer_id IS NOT NULL
ON CONFLICT (tevo_performer_id) DO UPDATE SET active=true, updated_at=now();
