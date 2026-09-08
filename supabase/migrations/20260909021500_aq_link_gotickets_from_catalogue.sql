-- Migration 20260909021500 · level:data-collection · lane:A1 · writes:aq_event_map,cron.job · reads:aq_event_map,gotickets_event · pre:20260909012000
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction.
-- Verified: aq_link_gotickets_from_catalogue() returned 471 on its first run,
-- matching the dry run exactly; hub rows with a GT id 5,845 -> 6,316; cron
-- aq_link_gotickets_catalogue_hourly created (jobid 587) at '40 * * * *'.
-- CRM future orders reaching a GT event id: 55.4% -> 77.4% (Gametime-sourced
-- 54.0 -> 83.0, StubHub 54.1 -> 76.7, GoTickets 56.2 -> 71.5). The +6,118
-- orders come from ~470 newly-covered events at ~13 orders each, concentrated
-- in high-volume NFL games spot-checked by hand (Baltimore Ravens at
-- Indianapolis Colts @ Lucas Oil, 328 orders; Raiders at Chargers @ SoFi, 312
-- -- exact name and venue on both sides). Re-running is idempotent (gated on
-- gotickets_event_id IS NULL).
--
-- Fill aq_event_map.gotickets_event_id from the GoTickets CATALOGUE, with
-- independent verification of the catalogue's own TEvo claim.
--
-- ⚠ NAMING — "GT" IN THIS FILE ALWAYS MEANS GOTICKETS, NEVER GAMETIME. Both
-- are marketplaces we carry (Gametime is 4,016 future CRM orders, GoTickets
-- 3,125), and both invite the same abbreviation. The schema keeps them apart by
-- always spelling Gametime out -- `gametime_event_id`, `gametime_url` -- while
-- every `gt_*` / `gotickets_*` identifier is GoTickets. `evd_event_id_crosswalk`
-- carries BOTH columns side by side, spelled out, and is the place to look if
-- you ever need to confirm which is which. The local aliases below (`g1`,
-- `gt_event_id`, `gt_name`, `gt_venue`) are all GoTickets columns off
-- `gotickets_event`; nothing here reads or writes any Gametime surface.
--
-- WHY. `gotickets_event` already carries a `tevo_event_id` (+ `mapped_via`,
-- `map_score`) for 4,641 of its 222,434 rows. The hub never reads it. So a hub
-- row can hold a tevo_event_id, the catalogue can hold the SAME tevo_event_id
-- against a GT event, and the hub's gotickets_event_id still sits NULL. That
-- gap is why CRM orders sold ON GoTickets reach a GT event id only 56.2% of the
-- time (measured 2026-09-08) — the hub's GT ids come from GT's own curated
-- feed, and the catalogue ingest was never joined to them.
--
-- ⚠ THE CATALOGUE'S tevo_event_id IS NOT TRUSTWORTHY ON ITS OWN. Joining on it
-- alone would import GT's mapping errors wholesale — the same failure the
-- venue-xref alias guard was written for (mig 20260908203500). Measured against
-- the 23 rows where the catalogue disagrees with a GT id the hub already holds:
--
--   score 1.000  "2026-2027 Los Angeles Lakers Season Tickets"
--             -> "NBA Preseason - Denver Nuggets at Los Angeles Lakers"
--                (4 of 12 sampled: season-ticket PACKAGES mapped to a single
--                 game, at MAXIMUM confidence — score is no defence here)
--   score 0.486  "Florida Gators at Auburn Tigers Football" @ Jordan-Hare
--             -> "North Greenville Crusaders at West Alabama Tigers" @ Tiger
--                Stadium - AL   (`instant_performer` matched on "Tigers")
--   score 0.536  US Open sub-venues conflated: Arthur Ashe <-> Louis Armstrong
--                <-> Grandstand, all sharing one tevo_event_id
--
-- So every guard below re-derives agreement from the DATA, and the catalogue's
-- map_score is deliberately NOT used as a gate: it is 1.000 on the worst false
-- matches in the set and 0.457 on a correct one ("Budweiser Guns 'N Hoses" ->
-- "Guns and Hoses Boxing Tournament" @ Enterprise Center).
--
-- THE GUARDS, and what each one is for:
--
-- 1. count(DISTINCT gt_event_id) = 1 per tevo_event_id. 97 TEvo ids carry more
--    than one GT event; none is fillable without picking arbitrarily.
--
-- 2. Season-ticket + parking exclusions on BOTH sides. The package-to-game
--    class above is the single worst error in the catalogue.
--
-- 3. NAME agreement — aq_name_consistent() + >= 2 shared tokens of >= 4 chars,
--    the same pair rules 6/7 of s4kcs_map_events() use.
--
-- 4. VENUE agreement — >= 1 shared token of >= 4 chars, MINUS the generic-word
--    stop-list from mig 20260908203500. The stop-list is load-bearing, not
--    cosmetic: without it "Arthur Ashe Stadium" and "Louis Armstrong Stadium"
--    share "stadium" and every US Open sub-venue swap passes.
--
-- 5. SESSION-NUMBER equality when both names carry "session N". Without it
--    "US Open Tennis - Session 16" binds to "... Session 15".
--
-- 6. MULTI-COURT COMPLEX exclusion. Guards 4 and 5 are still not enough: the
--    sub-venues of a tennis complex share the complex's PROPER NOUNS, so
--    "Billie Jean King National Tennis Center" and "Louis Armstrong Stadium at
--    the Billie Jean King National Tennis Center" overlap on billie/jean/king
--    and a "Grounds Admission" ticket binds to a specific court session. Same
--    shape at Cincinnati ("Center Court" -> "Grandstand Court at Lindner
--    Family Tennis Center"). The class is excluded outright rather than
--    approximated.
--
-- 7. DATE agreement within +/- 1.5 days. Wide on purpose: `gotickets_event`
--    stores UTC while `aq_event_map.event_date` mixes zones (PROJECT_BIBLE §3
--    landmine), so a correct pair can legitimately sit a day apart.
--
-- MEASURED (2026-09-08): 802 rows joinable on tevo_event_id alone -> 471 after
-- the guards (431 future), 400 distinct GT events. The 331 rejected are the
-- error classes above, not near-misses. The whole surviving low-score tail was
-- read row by row; every pair is the same real event.
--
-- EXISTING VALUES ARE NEVER OVERWRITTEN — gated on gotickets_event_id IS NULL.
-- The 23 known conflicts are therefore left exactly as they are; deciding which
-- side is right there is a separate job, and the catalogue is the less reliable
-- of the two.
--
-- REVERSIBLE: this is the only writer of gotickets_event_id whose rows can be
-- identified by their provenance column, so revert by schedule + the id set:
--   SELECT cron.unschedule('aq_link_gotickets_catalogue_hourly');
--   DROP FUNCTION public.aq_link_gotickets_from_catalogue();

CREATE OR REPLACE FUNCTION public.aq_link_gotickets_from_catalogue()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'aq_link_gotickets_from_catalogue: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  WITH g1 AS (
    SELECT tevo_event_id,
           min(gt_event_id)    AS gt_event_id,
           min(name)           AS gt_name,
           min(venue_name)     AS gt_venue,
           min(event_time_utc) AS gt_time
      FROM public.gotickets_event
     WHERE tevo_event_id IS NOT NULL
       AND status IS DISTINCT FROM 'cancelled'
     GROUP BY 1
    -- Guard 1: one GT event per TEvo event, or we would be picking arbitrarily.
    HAVING count(DISTINCT gt_event_id) = 1
  )
  UPDATE public.aq_event_map m
     SET gotickets_event_id = g.gt_event_id
    FROM g1 g
   WHERE g.tevo_event_id = m.tevo_event_id
     AND m.gotickets_event_id IS NULL
     AND m.event_name IS NOT NULL
     AND m.venue_name IS NOT NULL
     -- Guard 2: the catalogue maps season-ticket PACKAGES to single games at
     -- score 1.000. Excluded on both sides, with parking.
     AND m.event_name !~* 'season tickets?' AND g.gt_name !~* 'season tickets?'
     AND m.event_name NOT ILIKE '%parking%' AND g.gt_name NOT ILIKE '%parking%'
     AND m.venue_name NOT ILIKE '%parking%'
     -- Guard 6: multi-court complexes, whose sub-venues share proper nouns.
     AND m.event_name !~* 'grounds admission|grandstand'
     AND g.gt_name    !~* 'grounds admission|grandstand'
     AND m.venue_name !~* 'tennis cent(er|re)'
     AND g.gt_venue   !~* 'tennis cent(er|re)'
     -- Guard 3: name agreement, derived from the data not from the catalogue.
     AND public.aq_name_consistent(public.unaccent(g.gt_name), public.unaccent(m.event_name))
     AND (SELECT count(*) FROM (
           SELECT unnest(string_to_array(trim(regexp_replace(lower(
                    regexp_replace(public.unaccent(m.event_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           INTERSECT
           SELECT unnest(string_to_array(trim(regexp_replace(lower(
                    regexp_replace(public.unaccent(g.gt_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
         ) q(tok) WHERE length(tok) >= 4) >= 2
     -- Guard 4: venue agreement MINUS generic words. Without the stop-list,
     -- "Arthur Ashe Stadium" and "Louis Armstrong Stadium" share "stadium".
     AND EXISTS (SELECT 1 FROM (
           SELECT unnest(string_to_array(trim(regexp_replace(lower(
                    regexp_replace(public.unaccent(m.venue_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           INTERSECT
           SELECT unnest(string_to_array(trim(regexp_replace(lower(
                    regexp_replace(public.unaccent(g.gt_venue),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
         ) w(tok) WHERE length(tok) >= 4
           AND tok NOT IN ('stadium','park','arena','center','centre','field','theatre','theater',
                           'hall','parking','coliseum','pavilion','amphitheatre','amphitheater',
                           'garden','gardens','court','courts','sports','complex','grounds','club'))
     -- Guard 5: session numbers must agree when both sides carry one.
     AND ((m.event_name !~* 'session\s*\d+' OR g.gt_name !~* 'session\s*\d+')
          OR (regexp_match(lower(m.event_name), 'session\s*(\d+)'))[1]
           = (regexp_match(lower(g.gt_name),    'session\s*(\d+)'))[1])
     -- Guard 7: +/- 1.5 days — GT stores UTC, the hub column mixes zones.
     AND abs(EXTRACT(epoch FROM (g.gt_time - m.event_date)) / 86400.0) <= 1.5;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

REVOKE ALL ON FUNCTION public.aq_link_gotickets_from_catalogue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aq_link_gotickets_from_catalogue() TO service_role;

-- Ungated hourly, matching the local-backfill precedent (job 320
-- resolve-aq-tevo-from-sources-hourly). Own SET prefix per the §3 pg_cron
-- pool-leak landmine. At ':40', ahead of the ':45'/':50' hub fills so a GT id
-- landed here is visible to them in the same hour.
SELECT cron.schedule(
  'aq_link_gotickets_catalogue_hourly',
  '40 * * * *',
  $cron$
  SET statement_timeout='180s';
  SELECT public.aq_link_gotickets_from_catalogue();
  $cron$
);
