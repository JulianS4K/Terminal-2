-- Migration 20260909210000 · level:data-collection · lane:A1 · writes:gotickets_event · reads:aq_event_map,events,gotickets_event · pre:20260909200000
--
-- Already applied to prod · via MCP 2026-09-09 under operator direction.
-- Verified: filled 244 catalogue rows (88 future); gotickets_event now carries
-- mapped_via='hub_backfill' on exactly those rows, alongside GoTickets' own
-- instant_performer (3,951) / matcher_v3_got (312) / evo_gt_near (274) etc.
--
-- Writes the link back the OTHER way: hub -> catalogue.
--
-- The hub knows 5,956 (gotickets_event_id, tevo_event_id) pairs. 4,200 of them
-- already agreed with gotickets_event.tevo_event_id, but 264 catalogue rows sat
-- NULL despite the hub knowing the answer. Those are now filled, so the
-- catalogue is useful to anything that reads it directly rather than through
-- the hub -- including aq_link_gotickets_from_catalogue(), which only ever sees
-- catalogue rows GoTickets mapped itself.
--
-- ============================================================================
-- ⚠ THE HUB IS NOT AUTHORITATIVE -- GUARDS ARE RE-APPLIED, NOT ASSUMED.
-- ============================================================================
-- The hub already contains bad pairings, and a naive backfill would LAUNDER
-- them: written into the catalogue they become indistinguishable from
-- GoTickets' own mapping, and from_catalogue() would later read them back as
-- if GT had asserted them. Two classes caught in the dry run:
--
--   GT  "US Open Tennis - Grounds Pass - Tuesday Admission"
--         @ Billie Jean King National Tennis Center
--   <-  TEvo "2026 US Open Tennis Championship - Day Session - Session 5
--             (Grandstand Only)" @ Grandstand - Billie Jean King NTC
--       A grounds pass is not a Grandstand session, and the venues differ.
--       (4 of these, Tue/Wed/Thu/Fri.)
--
--   GT  "Los Angeles Lakers Season Tickets (Includes Tickets to All Regular
--        Season Home Games)"
--   <-  TEvo "NBA Preseason - Denver Nuggets at Los Angeles Lakers"
--       A season-ticket package is not a single game. (5 of these.)
--
-- 264 raw -> 246 after guards -> 244 written (2 lost to the one-GT-per-TEvo
-- uniqueness gate). The 18 excluded are those two classes plus NFL/NBA
-- season-ticket products, which we deliberately never map.
--
-- ============================================================================
-- SUPPORT-ACT PREFIX ARM -- and why it is safe HERE specifically.
-- ============================================================================
-- The >= 2 shared-token floor produces false NEGATIVES on the commonest concert
-- pattern, where GT names the headliner and TEvo names the whole bill:
--     "Ed Sheeran"    vs "Ed Sheeran with Macklemore, Lukas Graham, and BIIRD"
--     "Robyn"         vs "Robyn with HorsegiirL and Zhala"
--     "Ken Carson"    vs "Ken Carson with Xaviersobased, Prettifun and DJ Moon"
--     "ZZ Top"        vs "ZZ Top with George Thorogood and The Destroyers"
-- "ZZ Top" has NO >= 4-char token at all, so no token rule can ever reach it.
-- A normalised whole-string prefix (shorter side >= 5 chars) accepts these.
--
-- ⚠ That rule is only safe because THIS function's pairs come from the hub,
-- which already fixes venue AND date. Do NOT copy the prefix arm into a matcher
-- that is still searching for the venue or date -- there it degenerates into
-- the PROJECT_BIBLE §4 "Memorial Stadium" prefix landmine.
--
-- PROVENANCE: mapped_via='hub_backfill' marks these as DERIVED from our hub
-- rather than asserted by GoTickets. Without the marker a hub-derived link
-- would be indistinguishable from a catalogue-native one and the circularity
-- would be invisible.
--
-- NOT TOUCHED: 36 rows where the catalogue already holds a DIFFERENT
-- tevo_event_id than the hub. The update is gated on tevo_event_id IS NULL, so
-- no existing value is overwritten. Which side is right there is a separate
-- adjudication -- see the §4 note that the catalogue is the less reliable side.
--
-- REVERSIBLE, precisely, because of the provenance marker:
--   UPDATE public.gotickets_event
--      SET tevo_event_id = NULL, mapped_via = NULL, mapped_at = NULL
--    WHERE mapped_via = 'hub_backfill';

CREATE OR REPLACE FUNCTION public.gotickets_backfill_tevo_from_hub()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'gotickets_backfill_tevo_from_hub: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;

  WITH known AS (
    SELECT DISTINCT gotickets_event_id AS gt_id, tevo_event_id
      FROM public.aq_event_map
     WHERE gotickets_event_id IS NOT NULL AND tevo_event_id IS NOT NULL
  ), cand AS (
    SELECT g.gt_event_id, k.tevo_event_id, g.name AS gt_name, e.name AS tevo_name,
           regexp_replace(lower(public.unaccent(g.name)),'[^a-z0-9]+','','g') AS gk,
           regexp_replace(lower(public.unaccent(e.name)),'[^a-z0-9]+','','g') AS tk
      FROM known k
      JOIN public.gotickets_event g ON g.gt_event_id = k.gt_id AND g.tevo_event_id IS NULL
      JOIN public.events e ON e.id = k.tevo_event_id
  ), ok AS (
    SELECT gt_event_id, min(tevo_event_id) AS tevo_event_id
      FROM cand
     -- The hub is NOT authoritative; re-apply the linkers' guards or this
     -- launders known-bad pairings into the catalogue. See header for the two
     -- classes this caught (US Open grounds-pass, season-ticket -> single game).
     WHERE gt_name   !~* 'camping|grandstand|grounds admission|grounds pass|pass only'
       AND tevo_name !~* 'camping|grandstand|grounds admission|grounds pass|pass only'
       AND gt_name !~* 'season tickets?' AND tevo_name !~* 'season tickets?'
       AND gt_name NOT ILIKE '%parking%' AND tevo_name NOT ILIKE '%parking%'
       AND ((tevo_name !~* 'session\s*\d+' OR gt_name !~* 'session\s*\d+')
            OR (regexp_match(lower(tevo_name),'session\s*(\d+)'))[1]
             = (regexp_match(lower(gt_name),'session\s*(\d+)'))[1])
       AND public.aq_name_consistent(public.unaccent(gt_name), public.unaccent(tevo_name))
       AND (
         gk = tk
         -- Support-act prefix. SAFE ONLY HERE: the hub pairing already fixes
         -- venue and date. In a matcher still searching for those, this
         -- degenerates into the §4 "Memorial Stadium" prefix landmine.
         OR (length(least(gk,tk)) >= 5 AND (gk LIKE tk || '%' OR tk LIKE gk || '%'))
         OR (SELECT count(*) FROM (
               SELECT unnest(string_to_array(trim(regexp_replace(lower(
                        regexp_replace(public.unaccent(tevo_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
               INTERSECT
               SELECT unnest(string_to_array(trim(regexp_replace(lower(
                        regexp_replace(public.unaccent(gt_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             ) q(tok) WHERE length(tok) >= 4) >= 2)
     GROUP BY 1
    HAVING count(DISTINCT tevo_event_id) = 1
  )
  UPDATE public.gotickets_event g
     SET tevo_event_id = ok.tevo_event_id,
         mapped_via = 'hub_backfill',   -- provenance: derived, not GT-asserted
         mapped_at  = now()
    FROM ok
   WHERE g.gt_event_id = ok.gt_event_id
     AND g.tevo_event_id IS NULL;       -- never overwrite; 36 conflicts left alone
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;
REVOKE ALL ON FUNCTION public.gotickets_backfill_tevo_from_hub() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gotickets_backfill_tevo_from_hub() TO service_role;
