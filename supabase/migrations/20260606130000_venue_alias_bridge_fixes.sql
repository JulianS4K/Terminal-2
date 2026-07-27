-- Migration 20260606130000 · lane:D0 · writes: cross_source_venue_map (sg_aliases
--   on 4 venues + 1 new row) · then operationally re-runs the SG->TEvo matcher
--   + hub backfill · reads: sg_events_canonical, events
--
-- ## Already applied to prod · Applied via MCP 2026-06-06 (operator-authorized)
--
-- Venue-alias bridge fixes.
-- Several upcoming TEvo events had a demonstrable SeatGeek twin (same matchup,
-- same date) but never linked, because SeatGeek names the venue differently and
-- cross_source_venue_map carried no sg alias -> cross_source_venue_resolve()
-- returned NULL -> the SG->TEvo search bridge fell back to name-only search and
-- failed. Root case: "Chicago Fire at Inter Miami CF" at Miami Freedom Park &
-- Soccer Village (TEvo 3224515), which SeatGeek lists at "Nu Stadium".
--
-- Five venues are true same-building name differences and are safe to alias:
--   63463 Miami Freedom Park & Soccer Village  <- SG "Nu Stadium"
--   43437 Las Vegas Strip Circuit              <- SG "F1 Las Vegas Strip Autodrome"
--    1036 Centre Bell                          <- SG "Bell Centre" (word order)
--   31717 Memorial Stadium Oklahoma            <- SG "Oklahoma Memorial Stadium" (word order)
--     760 Jordan Hare Stadium                  <- SG "Jordan-Hare Stadium" (punctuation; no map row existed)
--
-- Deliberately NOT aliased (different physical venues -- aliasing would corrupt
-- the map): PayPal Park vs Stanford Stadium (a one-game relocation of an
-- Earthquakes match) and State Farm Arena vs Gateway Center Arena/College Park
-- (Atlanta Dream games; SG copies mostly CANCELLED). Left for per-event review.
--
-- After the alias writes below, the following were run operationally (not DDL):
--   select public.auto_match_sg_canonical_v3();  -- 17 newly_matched
--   select public.backfill_aq_maps();            -- ev_tevo_id=17 propagated to hub
-- Result: the full Inter Miami home slate (incl. Chicago Fire @ Inter Miami)
-- linked SG<->TEvo. (F1 Las Vegas events resolve the venue now but still miss the
-- matcher's name-consistency gate -- divergent event naming -- follow-up.)

update public.cross_source_venue_map
  set sg_aliases = sg_aliases || to_jsonb('Nu Stadium'::text), updated_at = now()
  where tevo_venue_id = 63463 and not (sg_aliases ? 'Nu Stadium');

update public.cross_source_venue_map
  set sg_aliases = sg_aliases || to_jsonb('F1 Las Vegas Strip Autodrome'::text), updated_at = now()
  where tevo_venue_id = 43437 and not (sg_aliases ? 'F1 Las Vegas Strip Autodrome');

update public.cross_source_venue_map
  set sg_aliases = sg_aliases || to_jsonb('Bell Centre'::text), updated_at = now()
  where tevo_venue_id = 1036 and not (sg_aliases ? 'Bell Centre');

update public.cross_source_venue_map
  set sg_aliases = sg_aliases || to_jsonb('Oklahoma Memorial Stadium'::text), updated_at = now()
  where tevo_venue_id = 31717 and not (sg_aliases ? 'Oklahoma Memorial Stadium');

-- 760 had no map row; canonical_name + sources_count are generated columns (omit).
insert into public.cross_source_venue_map (tevo_venue_id, tevo_venue_name, city, state, country, sg_aliases)
select 760, 'Jordan Hare Stadium', 'Auburn', 'AL', 'US', to_jsonb(array['Jordan-Hare Stadium'])
where not exists (select 1 from public.cross_source_venue_map where tevo_venue_id = 760);
