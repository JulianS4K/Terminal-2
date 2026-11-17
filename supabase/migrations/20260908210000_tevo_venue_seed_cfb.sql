-- Migration 20260908210000 · level:data-collection · lane:A1 · writes:cross_source_venue_map · reads:none · pre:20260908203500
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. All six
-- ids were verified against GET /v9/venues/<id> BEFORE seeding — every id, name,
-- city and state matches the decoded URL exactly, and TEvo's own `keywords` field
-- independently confirmed the "LSU Tiger Stadium" and "Merchants Bank Field"
-- aliases derived by hand here.
-- Result: all name variants resolve (McLane Stadium correctly still does NOT),
-- 53 stale no_results/low_score attempts were cleared for these venues so the
-- bridge would re-try them, and ~47 of 59 blocked hub rows matched across three
-- runs with 1 no_result. Spot-checked every binding: e.g. hub "Florida Gators vs.
-- Campbell Fighting Camels" -> TEvo "Campbell Fighting Camels at Florida Gators
-- Football" @ venue 133, and hub "Memorial Stadium - IN" -> venue 2044 via the
-- new alias. s4kcs_map_events() then mapped 198 more CRM orders; future CRM order
-- coverage 74.9% -> 79.9%, future hub 82.3% -> 83.1%.
--
-- Seed six TEvo venue ids supplied by the operator, and give the resolver two
-- alias columns it was not reading.
--
-- WHY THIS IS HAND-SEEDED. These ids came from the operator's own TEvo console
-- URLs, whose filter segment is base64 JSON:
--     .../filter/eyJ2ZW51ZV9pZCI6NzkzLCJ2ZW51ZV9uYW1lIjoiS2lubmljayBTdGFkaXVtIn0=/3242992/all
--   → {"venue_id":793,"venue_name":"Kinnick Stadium"}      (event 3242992)
-- The venue ids could not be discovered any other way from here:
-- /v9/venues ignores name=, name[]= and q= alike (all three return the full
-- 24,988-row index), and only /v9/searches?entities=venues&q= filters at all.
--
--   793  Kinnick Stadium                            ev 3242992
--   873  Tiger Stadium - Baton Rouge                ev 3327629
--   133  Ben Hill Griffin Stadium                   ev 3240389
--  2044  Merchants Bank Field at Memorial Stadium   ev 3243907
--   413  Doak Campbell Stadium                      ev 3304030
--   826  Lane Stadium                               ev 3238532
--   975  Gies Memorial Stadium                      ev 3356724  (already seeded,
--                                                    mig 20260908184118)
-- The event ids are not seeded — they are the verification target. Once the
-- venue resolves, the bridge's venue_id+date search should discover them on its
-- own; if it does not, the failure is in the bridge, not the venue map.
--
-- SIZE OF THE PRIZE (measured 2026-09-08, future CRM orders behind these six):
--   Kinnick 296 · LSU Tiger 199 · Ben Hill Griffin 146 · Merchants Bank 145 ·
--   Doak Campbell 116 · Lane 99  = ~1,001 orders, the top of the unmapped list.
-- Every one of them returns NULL from cross_source_venue_resolve() today, which
-- is why their hub rows have no tevo_event_id and their CRM orders cannot map.
--
-- HOW THE NAME VARIANTS RESOLVE. canonical_name is GENERATED as
-- lower(regexp_replace(tevo_venue_name,'[^a-z0-9]+','','gi')), and the resolver
-- has a prefix branch, so most variants land without an alias:
--     "Kinnick Stadium"                          -> exact
--     "Kinnick Stadium - Iowa City, IA"          -> prefix branch
--     "Merchants Bank Field At Memorial Stadium" -> exact (case folded)
--     "Tiger Stadium Baton Rouge"                -> exact
--     "Tiger Stadium"                            -> prefix branch
-- One does NOT: "LSU Tiger Stadium" canonicalizes to 'lsutigerstadium', which
-- is neither a prefix of nor prefixed by 'tigerstadiumbatonrouge'. It needs a
-- real alias, and that exposed a gap — see below.
--
-- NOT A COLLISION: "McLane Stadium" (Baylor) is a different venue and stays
-- unresolved. 'mclanestadium' is neither a prefix of nor prefixed by
-- 'lanestadium', so seeding Lane Stadium cannot capture it. Verified before
-- seeding, because a venue prefix rule is exactly where that would go wrong.
--
-- TWO ALIAS COLUMNS THE RESOLVER WAS NOT READING. Its alias branch checks
-- sg_aliases / tickpick_aliases / vivid_aliases only. That leaves no home for a
-- CRM or hub venue string, and it silently orphaned gotickets_aliases, which
-- mig 20260908202400 had just populated for 366 venues. So:
--   * add crm_aliases (the home for CRM/hub-side venue strings), and
--   * widen the alias branch to read crm_aliases and gotickets_aliases too.
-- Strictly widening: no existing branch, ordering or return changes, and the
-- alias test stays exact jsonb containment (`?`), never fuzzy. Measured effect
-- of the gotickets_aliases half on its own: 5 of the 186 unresolved venue names
-- begin resolving.
--
-- ⚠ LANDMINE FOUND WHILE DOING THIS, NOT INTRODUCED BY IT. Bare "Memorial
-- Stadium" resolves to 31717 (Memorial Stadium OKLAHOMA) through the prefix
-- branch: 'memorialstadiumoklahoma' LIKE 'memorialstadium%'. There are at least
-- ten distinct Memorial Stadiums in this data (Oklahoma, Indiana, Nebraska,
-- Kansas, Illinois, Clemson, Texas/DKR, Missouri/Faurot, Navy-Marine Corps,
-- NMSU), so that resolution is a coin flip, and the bridge would score a
-- venue_id hit at 50 — enough to pass with only a generic shared token like
-- "Football".
-- EXPOSURE TODAY IS ZERO, verified before seeding: no aq_event_map row uses the
-- bare string (0 rows), the only hub row bound to 31717 is "Memorial Stadium -
-- OK" -> Oklahoma which is CORRECT, and no bridge attempt has searched 31717 for
-- a non-Oklahoma stadium. The 133 CRM orders that do say bare "Memorial Stadium"
-- go through s4kcs_map_events(), which matches venue strings against the hub
-- directly and never calls this resolver.
-- So this migration does NOT change the prefix branch — doing so under a live
-- bridge to fix a latent bug with no occurrences would be the riskier act. The
-- suffixed forms are safe by construction ('memorialstadiumin' neither prefixes
-- nor is prefixed by 'memorialstadiumoklahoma'), and the aliases above give
-- Indiana and Illinois exact resolutions that win before the prefix branch runs.
-- Recorded in PROJECT_BIBLE §3; the real fix is city/state on the prefix branch.
--
-- REVERSIBLE:
--   DELETE FROM public.cross_source_venue_map
--    WHERE tevo_venue_id IN (793,873,133,2044,413,826);   -- 975 predates this
--   UPDATE public.cross_source_venue_map SET crm_aliases = '[]'::jsonb;
--   -- then re-apply the resolver body from mig 20260601 (drop the two new ORs).

ALTER TABLE public.cross_source_venue_map
  ADD COLUMN IF NOT EXISTS crm_aliases jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.cross_source_venue_map.crm_aliases IS
  'Venue strings as the S4K CRM / aq_event_map hub spell them, when they do not canonicalize to the TEvo name (e.g. "LSU Tiger Stadium" for tevo 873 "Tiger Stadium - Baton Rouge"). Read by cross_source_venue_resolve().';

-- canonical_name and sources_count are GENERATED ALWAYS — never in the column list.
INSERT INTO public.cross_source_venue_map
      (tevo_venue_id, tevo_venue_name, city, state, country)
VALUES
  ( 793, 'Kinnick Stadium',                          'Iowa City',   'IA', 'US'),
  ( 873, 'Tiger Stadium - Baton Rouge',              'Baton Rouge', 'LA', 'US'),
  ( 133, 'Ben Hill Griffin Stadium',                 'Gainesville', 'FL', 'US'),
  (2044, 'Merchants Bank Field at Memorial Stadium', 'Bloomington', 'IN', 'US'),
  ( 413, 'Doak Campbell Stadium',                    'Tallahassee', 'FL', 'US'),
  ( 826, 'Lane Stadium',                             'Blacksburg',  'VA', 'US')
ON CONFLICT (tevo_venue_id) DO NOTHING;

-- Aliases. Every string below is one the hub or the CRM actually uses today AND
-- (where quoted) one TEvo lists in the venue's own `keywords` field, fetched from
-- /v9/venues/<id> while verifying these ids:
--    873  keywords "LSU Tiger Stadium"
--   2044  keywords "... , Merchants Bank Field"
--    975  keywords "Gies Memorial Stadium, Memorial Stadium- IL"
-- "Memorial Stadium - IN" / "Memorial Stadium Indiana" are not TEvo keywords but
-- are what our hub and CRM call venue 2044 (5 hub rows / 75 CRM orders), and the
-- venue's own city+state (Bloomington, IN) corroborates them.
UPDATE public.cross_source_venue_map
   SET crm_aliases = '["LSU Tiger Stadium"]'::jsonb, updated_at = now()
 WHERE tevo_venue_id = 873 AND crm_aliases = '[]'::jsonb;

UPDATE public.cross_source_venue_map
   SET crm_aliases = '["Merchants Bank Field","Memorial Stadium - IN","Memorial Stadium Indiana"]'::jsonb,
       updated_at = now()
 WHERE tevo_venue_id = 2044 AND crm_aliases = '[]'::jsonb;

UPDATE public.cross_source_venue_map
   SET crm_aliases = '["Memorial Stadium- IL"]'::jsonb, updated_at = now()
 WHERE tevo_venue_id = 975 AND crm_aliases = '[]'::jsonb;

CREATE OR REPLACE FUNCTION public.cross_source_venue_resolve(p_venue_name text, p_city text DEFAULT NULL::text, p_state text DEFAULT NULL::text)
RETURNS bigint
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_canonical text;
  v_id bigint;
BEGIN
  IF p_venue_name IS NULL OR p_venue_name = '' THEN RETURN NULL; END IF;
  v_canonical := lower(regexp_replace(p_venue_name, '[^a-z0-9]+', '', 'gi'));

  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE canonical_name = v_canonical
    AND (p_city IS NULL OR city IS NULL OR lower(city) = lower(p_city))
    AND (p_state IS NULL OR state IS NULL OR upper(state) = upper(p_state))
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- Alias branch. crm_aliases and gotickets_aliases added 20260908210000 —
  -- both existed as data with nothing reading them. Exact containment only.
  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE sg_aliases        ? p_venue_name
     OR tickpick_aliases  ? p_venue_name
     OR vivid_aliases     ? p_venue_name
     OR gotickets_aliases ? p_venue_name
     OR crm_aliases       ? p_venue_name
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE canonical_name LIKE v_canonical || '%'
     OR v_canonical LIKE canonical_name || '%'
  ORDER BY length(canonical_name) DESC
  LIMIT 1;
  RETURN v_id;
END $function$;
