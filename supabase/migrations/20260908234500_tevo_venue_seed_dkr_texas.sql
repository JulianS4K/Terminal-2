-- Migration 20260908234500 · level:data-collection · lane:A1 · writes:cross_source_venue_map · reads:none · pre:20260908233000
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. Verified
-- against GET /v9/venues/1546 BEFORE seeding: id, name, city and state all match
-- the decoded URL. After seeding, all six non-parking spellings resolve to 1546.
--
-- Seed TEvo venue 1546 (Darrell K Royal Memorial Stadium, Austin TX) — the
-- largest single venue-id gap left, ~400 future CRM orders.
--
-- From an operator-supplied console URL:
--   .../filter/eyJ2ZW51ZV9pZCI6IjE1NDYiLCJ2ZW51ZV9uYW1lIjoiRGFycmVsbCBLIFJveWFsIE1lbW9yaWFsIFN0YWRpdW0ifQ==/3100765/all
--   -> {"venue_id":"1546","venue_name":"Darrell K Royal Memorial Stadium"}
--
-- ⚠ NOTE THE TYPE: venue_id arrives here as the STRING "1546", where the seven
-- URLs in mig 20260908210000 all carried an integer. Anything that parses these
-- filter payloads must not assume the type — read it as text and cast.
--
-- NINE SPELLINGS, ONE STADIUM. This venue is the clearest case yet for matching
-- on venue IDENTITY rather than venue string. Our data spells it:
--     Darrell K Royal                                    (crm)
--     Darrell K. Royal                                   (crm)
--     Darrell K Royal Memorial Stadium                   (hub)  = the TEvo name
--     Darrell K Royal - Texas Memorial Stadium           (hub)
--     Darrell K Royal-Texas Memorial Stadium             (crm)
--     Darrell K. Royal Texas Memorial Stadium            (crm)
--   + three parking variants, deliberately NOT aliased.
--
-- Two families resolve without help once the row exists: the bare "Darrell K
-- Royal"/"Darrell K. Royal" forms reach it through the prefix branch (unique —
-- no other venue shares that prefix, so the ambiguity guard from mig
-- 20260908224500 lets them through). The "...Texas Memorial Stadium" forms do
-- NOT: canonicalised they are 'darrellkroyaltexasmemorialstadium' against the
-- TEvo name's 'darrellkroyalmemorialstadium', and neither is a prefix of the
-- other — they diverge at "texas". Those three need explicit aliases.
--
-- The fourth alias, "Darrell K. Royal - Texas Memorial Stadium", is TEvo's OWN
-- `keywords` value for this venue, fetched during verification. It does not
-- appear in our data today; it is seeded because TEvo considers it canonical and
-- the CRM may start emitting it.
--
-- PARKING SPELLINGS EXCLUDED. Three of the nine are parking lots. They are left
-- unresolvable on purpose: aliasing them would point a parking row at the
-- stadium's venue id, which is the shape of the bug fixed in mig 20260908230000.
-- The bridge's candidate function already skips parking, so this costs nothing.
--
-- REVERSIBLE: DELETE FROM public.cross_source_venue_map WHERE tevo_venue_id = 1546;

INSERT INTO public.cross_source_venue_map
      (tevo_venue_id, tevo_venue_name, city, state, country, crm_aliases)
VALUES
  (1546, 'Darrell K Royal Memorial Stadium', 'Austin', 'TX', 'US',
   '["Darrell K Royal - Texas Memorial Stadium","Darrell K Royal-Texas Memorial Stadium","Darrell K. Royal Texas Memorial Stadium","Darrell K. Royal - Texas Memorial Stadium"]'::jsonb)
ON CONFLICT (tevo_venue_id) DO UPDATE
  SET crm_aliases = EXCLUDED.crm_aliases, updated_at = now();
