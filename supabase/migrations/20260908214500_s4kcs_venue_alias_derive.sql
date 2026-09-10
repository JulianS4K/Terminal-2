-- Migration 20260908214500 · level:data-collection · lane:A1 · writes:cross_source_venue_map · reads:s4kcs_orders,events · pre:20260908210000
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. First
-- run: 1 venue inserted, 8 aliases written, 0 skipped-as-claimed-elsewhere.
-- The count 8 (against 10 qualifying strings) is what exposed the multi-alias
-- bug fixed in mig 20260908215500 — see that file. After the corrective, all 10
-- are present and resolving, including the two corrections:
--   "Toyota Center"   1602 (Kennewick) -> 2786 (Houston)
--   "Orpheum Theatre" 1161 (Minneapolis) -> 2773 (Los Angeles)
--
-- Learn CRM venue-name aliases from orders we have ALREADY mapped, and write
-- them to cross_source_venue_map.crm_aliases so the resolver stops guessing.
--
-- WHY. The CRM and TEvo call the same building different things, and the
-- resolver's third branch is a bare prefix match with no city/state guard, so
-- an unknown spelling either fails or — worse — silently lands on the wrong
-- venue of the same name. Both failure modes are visible in the data today.
--
-- METHOD (same event-agreement idea as venue_xref_derive_from_events, applied
-- to the CRM side): for each CRM venue string, look at the TEvo venue of every
-- order already mapped from it. Accept only where every observation agrees
-- (`count(DISTINCT venue_id) = 1`) AND at least TWO DISTINCT EVENTS back it.
-- The two-event floor is load-bearing, not decoration:
--   "Indian Wells Tennis Garden" has ONE mapped order, pointing at Stadium 1.
--   Indian Wells is a multi-stadium complex and the bare name genuinely does
--   not identify a stadium, so a one-observation sample would have written a
--   coin flip as fact. It is skipped, along with 72 other single-event strings.
-- Note the SPECIFIC string "Stadium 1 at Indian Wells Tennis Garden" has four
-- events behind it and IS written — the guard drops the ambiguous name while
-- keeping the unambiguous one.
--
-- WHAT IT WRITES (measured 2026-09-08 — 211 strings qualify, 201 already
-- resolve correctly and are no-ops, 10 are written):
--   "The Kia Forum" / "The Forum"                -> 602   Kia Forum
--   "Toyota Center"                              -> 2786  Toyota Center - TX      *
--   "Las Vegas Strip Circuit" / "... Street ..."  -> 43437 Las Vegas Strip Autodrome
--   "The Rose Bowl"                              -> 1342  Rose Bowl Stadium - Pasadena
--   "Stadium 1 at Indian Wells Tennis Garden"    -> 3751  Indian Wells TG - Stadium 1
--   "Guaranteed Rate Field"                      -> 318   Rate Field              (renamed)
--   "Orpheum Theatre"                            -> 2773  Orpheum Theatre - LA    *
--   "Keeneland"                                  -> 2571  Keeneland
--   * = CORRECTS A WRONG RESOLUTION, not merely a missing one.
--
-- THE TWO CORRECTIONS ARE THE POINT. Before this migration:
--     "Toyota Center"   resolved to 1602 (Toyota Center - KENNEWICK, WA)
--                       while its 47 mapped orders are all Houston (2786).
--     "Orpheum Theatre" resolved to 1161 (MINNEAPOLIS) while its orders are
--                       Los Angeles (2773).
-- This is the same prefix-branch ambiguity recorded in `PROJECT_BIBLE §4` for
-- bare "Memorial Stadium" — but with live instances rather than latent risk.
-- Writing the alias FIXES it, because the resolver's alias branch runs BEFORE
-- the prefix branch, so an exact alias hit now wins.
--
-- NO DAMAGE HAD BEEN DONE, verified before writing: every hub row at these
-- venues is bound to the CORRECT TEvo venue (Toyota Center -> 2786 Houston,
-- Orpheum -> 2773 LA, Nederlander -> 1094 NY). The bridge's name+date fallback
-- had been covering for the bad venue id. Three unmapped "Toyota Center" hub
-- rows were still being pointed at Kennewick, though, so this is a fix ahead of
-- a failure, not after one.
--
-- NOT WRITTEN, deliberately: "Nederlander Theatre" (resolves to 519 Chicago,
-- truth 1094 NY) and bare "Indian Wells Tennis Garden" both fall under the
-- two-event floor. They stay wrong rather than being fixed on thin evidence —
-- the floor is worth more than the two rows it costs here.
--
-- SAFETY. Append-only into a jsonb array, and only when the string is not
-- already an alias somewhere: a string already claimed by a DIFFERENT venue row
-- is skipped and counted, never moved, because two rows claiming one alias
-- makes the resolver's `LIMIT 1` nondeterministic. Parking strings are excluded
-- (a parking lot is not the venue). Re-running is idempotent.
--
-- REVERSIBLE:
--   UPDATE public.cross_source_venue_map SET crm_aliases = '[]'::jsonb
--    WHERE id_provenance ? 'crm_aliases';

CREATE OR REPLACE FUNCTION public.s4kcs_venue_alias_derive(p_apply boolean DEFAULT true)
RETURNS TABLE(action text, n integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 's4kcs_venue_alias_derive: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  CREATE TEMP TABLE _al ON COMMIT DROP AS
  WITH obs AS (
    SELECT split_part(s.venue_name, ' - ', 1) AS vk,
           e.venue_id,
           count(DISTINCT s.tevo_event_id) AS n_events
      FROM public.s4kcs_orders s
      JOIN public.events e ON e.id = s.tevo_event_id
     WHERE s.tevo_event_id IS NOT NULL
       AND e.venue_id IS NOT NULL
       AND s.venue_name IS NOT NULL
       AND s.event_name  !~* '^(parking|parking pass)'
       AND s.venue_name NOT ILIKE '%parking%'
     GROUP BY 1, 2
  )
  SELECT vk, min(venue_id) AS venue_id, sum(n_events)::int AS n_events
    FROM obs
   GROUP BY vk
  -- Every observation must agree on one venue, backed by >= 2 distinct events.
  HAVING count(DISTINCT venue_id) = 1
     AND sum(n_events) >= 2;

  -- Drop the no-ops: strings the resolver already gets right.
  DELETE FROM _al a
   WHERE public.cross_source_venue_resolve(a.vk, NULL, NULL) = a.venue_id;

  -- Never move an alias another venue already claims — that would make the
  -- resolver's LIMIT 1 nondeterministic.
  SELECT count(*) INTO v_n
    FROM _al a
   WHERE EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                  WHERE m.tevo_venue_id <> a.venue_id
                    AND (m.crm_aliases ? a.vk OR m.sg_aliases ? a.vk
                         OR m.tickpick_aliases ? a.vk OR m.vivid_aliases ? a.vk));
  RETURN QUERY SELECT 'skipped_alias_claimed_elsewhere'::text, v_n;
  DELETE FROM _al a
   WHERE EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                  WHERE m.tevo_venue_id <> a.venue_id
                    AND (m.crm_aliases ? a.vk OR m.sg_aliases ? a.vk
                         OR m.tickpick_aliases ? a.vk OR m.vivid_aliases ? a.vk));

  IF NOT p_apply THEN
    RETURN QUERY SELECT 'would_write'::text, (SELECT count(*)::int FROM _al);
    RETURN;
  END IF;

  -- canonical_name / sources_count are GENERATED ALWAYS — never in the list.
  INSERT INTO public.cross_source_venue_map
        (tevo_venue_id, tevo_venue_name, tevo_venue_location, state)
  SELECT DISTINCT ON (e.venue_id) e.venue_id, e.venue_name, e.venue_location, e.state
    FROM public.events e
    JOIN _al a ON a.venue_id = e.venue_id
   WHERE e.venue_name IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                      WHERE m.tevo_venue_id = e.venue_id)
   ORDER BY e.venue_id, e.id DESC
  ON CONFLICT (tevo_venue_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venues_inserted'::text, v_n;

  UPDATE public.cross_source_venue_map m
     SET crm_aliases   = m.crm_aliases || to_jsonb(a.vk),
         id_provenance = m.id_provenance || jsonb_build_object('crm_aliases',
           jsonb_build_object('method','order_venue_agreement','derived_at',now())),
         updated_at    = now()
    FROM _al a
   WHERE m.tevo_venue_id = a.venue_id
     AND NOT (m.crm_aliases ? a.vk);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'aliases_written'::text, v_n;
END $function$;

REVOKE ALL ON FUNCTION public.s4kcs_venue_alias_derive(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_venue_alias_derive(boolean) TO service_role;

-- Daily, ahead of the venue xref (06:23) so a newly learned alias is in place
-- before the id derivation runs.
SELECT cron.schedule(
  's4kcs_venue_alias_derive_daily',
  '11 6 * * *',
  $cron$
  SET statement_timeout='120s';
  SELECT public.s4kcs_venue_alias_derive(true);
  $cron$
);
