-- Migration 20260908184118 · level:data-collection · lane:A1 · writes:cross_source_venue_map · reads:none · pre:20260908183242
-- Already applied to prod · via MCP 2026-09-08 (INSERT run directly, this file
-- is the idempotent codification; ON CONFLICT DO NOTHING makes re-apply a no-op).
--
-- Seed the TEvo venue the resolver was missing: Gies Memorial Stadium = 975.
--
-- WHY. cross_source_venue_resolve() reads this table, and the table is built
-- from our TEvo `events` mirror — which has no college-football coverage. So
-- the map holds 1,245 venues and ZERO for Gies or Kinnick. With no venue id,
-- aq-to-tevo-search-bridge could only run its WEAK name+date search, which
-- searched TEvo for the literal string "Illinois Fighting Illini Football" and
-- returned no_results. The strong venue+date search — the one that produced
-- essentially every successful match — never ran at all.
--
-- The id is authoritative: it comes from TEvo core's own venue filter blob,
-- {"venue_id":975,"venue_name":"Gies Memorial Stadium"}. It is NOT inferred.
--
-- canonical_name is GENERATED from tevo_venue_name -> 'giesmemorialstadium'.
-- That deliberately excludes the city/state tail, so the resolver's third
-- lookup (v_canonical LIKE canonical_name || '%') also catches the CRM's other
-- two spellings of this venue, which arrive per-marketplace:
--     "Gies Memorial Stadium"                 (Gametime / GoTickets / Vivid)
--     "Gies Memorial Stadium Illinois"        (StubHub)
--     "Gies Memorial Stadium - Champaign, IL" (hub system_seed rows)
-- All three verified resolving to 975 after this insert.
--
-- RESULT (verified end to end 2026-09-08): bridge found TEvo event 3356724 for
-- Duke at Illinois 2026-09-12 by venue+date — the same id the operator's TEvo
-- core URL pointed at, arrived at independently — and filled it onto 5 hub
-- rows. s4kcs_map_events() then mapped 214 CRM orders across all three venue
-- spellings and both name forms, via name_date_venue at confidence 0.98.
--
-- SCOPE. One venue. The same gap exists for ~122 other college-football venues
-- (Kinnick, Bryant-Denny, Tiger Stadium, Darrell K Royal, Doak Campbell, ...),
-- each needing its own TEvo venue id, which cannot be looked up from a session
-- with no TEvo egress. Doing them in bulk needs either TEvo venue search from
-- an environment that can reach it, or the operator supplying ids.
--
-- REVERSIBLE: DELETE FROM public.cross_source_venue_map WHERE tevo_venue_id = 975;

INSERT INTO public.cross_source_venue_map
  (tevo_venue_id, tevo_venue_name, tevo_venue_location, city, state, country)
VALUES
  (975, 'Gies Memorial Stadium', 'Champaign, IL', 'Champaign', 'IL', 'US')
ON CONFLICT DO NOTHING;
