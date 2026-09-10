-- Migration 20260908195605 · level:data-collection · lane:A1 · writes:aq_event_map,cron.job · reads:aq_event_map · pre:20260908194523
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction (recorded there
-- as its own version stamp). Verified: aq_link_tevo_from_sibling_rows() returned 237
-- on its first run, matching the dry run exactly (69 future, 168 past); cron
-- aq_link_tevo_siblings_hourly created at '50 * * * *'. Re-running is idempotent
-- (gated on tevo_event_id IS NULL).
--
-- Fill aq_event_map.tevo_event_id from a SIBLING HUB ROW instead of a TEvo
-- search: only ever match events that are actually unmatched.
--
-- WHY. The hub carries N rows per real event (PROJECT_BIBLE §3 — 592 duplicate
-- tevo_event_id groups today, up from 221 at the 2026-06-01 audit). When one of
-- those rows gets a tevo_event_id, its siblings stay NULL, and the aq-to-tevo
-- bridge then spends a TEvo request re-discovering an id we already hold. The
-- event is matched; the ROW is not. That is pure waste on both sides: an API
-- call we did not need, and a slot in a 50-row batch that a genuinely unknown
-- event could have used.
--
-- The existing local backfills do not reach these rows:
--   * link_aq_tevo_from_events() propagates by aq_short_event_id, so it only
--     covers duplicates that already share a short id. Measured: 0 of the 52
--     future rows below share a short id with their matched sibling.
--   * link_aq_tevo_from_events() and resolve_aq_tevo_from_sources() both join
--     the `events` mirror on EXACT venue_name equality. Every row here fails
--     that: 49 of 52 carry a venue string that differs from the sibling's.
-- This joins hub-to-hub instead, which is what makes it additive.
--
-- WHAT IT MATCHES. Exact normalized event name + same calendar date, where the
-- matched rows at that (name, date) agree on ONE tevo_event_id. Nearly all of
-- it is venue aliasing:
--     "The Forum"                             / "Kia Forum"
--     "The Rose Bowl"                         / "Rose Bowl Stadium"
--     "The O2 - London"                       / "O2 Arena - London"
--     "Oklahoma Memorial Stadium - Norman, OK"/ "Memorial Stadium - OK"
--     "Moda Center - Complex"                 / "Moda Center"
--
-- cross_source_venue_resolve() CANNOT serve as the guard here, which is why the
-- guard below is structural. Checked live: it resolves the canonical side
-- ("Kia Forum"→602, "Rose Bowl Stadium"→1342, "Moda Center"→1343) and returns
-- NULL for every alias side ("The Forum", "The Rose Bowl", "Moda Center -
-- Complex", "The O2 - London"). Seeding those aliases is worth doing, but it is
-- a separate job and this must not block on it.
--
-- THE TWO GUARDS.
--
-- 1. HAVING count(DISTINCT tevo_event_id) = 1 — load-bearing. Note it is the
--    count of EVENT IDS, deliberately not of venue strings: a (name, date)
--    group whose matched rows span three venue strings but one tevo_event_id is
--    CONFIRMING an alias, not signalling a conflict. That is the Klangkuenstler
--    @ 2026-10-03 case (3 venue strings → tevo 3396944), and excluding it would
--    throw away 12 correct fills for no safety gain.
--
-- 2. Venue-token overlap — >= 1 shared token of >= 4 chars between the
--    unmatched row's venue and at least one sibling venue. Same shape as the
--    matchup guard in mig 20260908173624. It passes every alias pair above
--    (forum / rose+bowl / london / memorial+stadium / moda+center) and rejects
--    exactly one row today, which is a REAL false match it was written for:
--        "Monster Jam" 2026-10-17 @ "Reliant Stadium"        (Houston, TX)
--        matched sibling @ "Numerica Veterans Arena"          (Yakima, WA)
--    Simultaneous tour legs share a name and a date. Without this guard that
--    binds a Houston order to a Washington event. §3 warns that date matching
--    without a second axis is what bound a Forrest Frank concert to a Knicks
--    game; this is the same failure mode one rung up.
--
-- The city/state columns are NOT usable as that second axis: city is NULL on 50
-- of the 52 future rows, so a city guard would reject 96% of correct fills
-- while catching nothing.
--
-- MEASURED (2026-09-08, dry run): 237 rows fill — 69 future, 168 past — with
-- 1 rejected by the venue guard and 0 ambiguous (no (name, date) group in the
-- whole hub maps to more than one tevo_event_id AND passes the guard).
--
-- PAST EVENTS INCLUDED, deliberately: this is a local join with no API call, so
-- the reason the bridge is restricted to `event_date >= now()` does not apply.
-- The 168 past fills make the CRM order archive joinable.
--
-- ROWS WITH sg_event_id INCLUDED (20 of the 237), also deliberately: that
-- exclusion exists in aq_tevo_search_candidates() to stop two bridges racing
-- for the same TEvo request. There is no request here, and the SG bridge only
-- ever writes rows where tevo_event_id IS NULL, so filling one cannot conflict.
--
-- COST. The hub is 18,378 rows; this is one grouped self-join, hourly, and it
-- writes nothing once the backlog is drained (every rule is gated on
-- tevo_event_id IS NULL). Ungated by cron_should_fire(), matching the existing
-- local-backfill precedent — job 320 resolve-aq-tevo-from-sources-hourly is a
-- bare `SELECT public.resolve_aq_tevo_from_sources();` at '35 * * * *'.
-- Scheduled at ':50', three minutes ahead of the bridge's ':53' mark, so a row
-- filled locally leaves the bridge's pool before the bridge pays for it.
--
-- REVERSIBLE: the fills are indistinguishable from any other tevo_event_id
-- once written, so revert by schedule, not by value:
--   SELECT cron.unschedule('aq_link_tevo_siblings_hourly');
--   DROP FUNCTION public.aq_link_tevo_from_sibling_rows();

CREATE OR REPLACE FUNCTION public.aq_link_tevo_from_sibling_rows()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'aq_link_tevo_from_sibling_rows: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  WITH sib AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date                                         AS d,
           min(a.tevo_event_id)                                       AS tid,
           array_agg(DISTINCT lower(trim(a.venue_name)))              AS sib_venues
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL
       AND a.event_name IS NOT NULL
       AND a.event_date IS NOT NULL
       AND a.venue_name IS NOT NULL
     GROUP BY 1, 2
    -- Guard 1: the matched rows must agree on ONE event. Counting event ids,
    -- not venue strings — see header.
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.aq_event_map m
     SET tevo_event_id = s.tid
    FROM sib s
   WHERE m.tevo_event_id IS NULL
     AND m.event_name IS NOT NULL
     AND m.event_date IS NOT NULL
     AND m.venue_name IS NOT NULL
     AND regexp_replace(lower(m.event_name), '[^a-z0-9]+', '', 'g') = s.nk
     AND m.event_date::date = s.d
     -- Same unmappable-product exclusions the bridge pool uses (mig 20260908183242).
     AND NOT (m.category IN ('Parking','parking')
              OR m.venue_name ILIKE '%parking%'
              OR m.event_name ILIKE '%parking%')
     AND NOT (m.event_name ~* '(cancelled|if necessary|\(date tbd\))')
     AND NOT (m.event_name ~* 'season tickets?')
     -- Guard 2: venue-token overlap. Catches same-name/same-date events at
     -- genuinely different venues (Monster Jam, header).
     AND EXISTS (
       SELECT 1
         FROM unnest(s.sib_venues) sv
        WHERE EXISTS (
          SELECT 1
            FROM unnest(regexp_split_to_array(
                   regexp_replace(lower(m.venue_name), '[^a-z0-9]+', ' ', 'g'), '\s+')) tok
           WHERE length(tok) >= 4
             AND tok = ANY(regexp_split_to_array(
                   regexp_replace(sv, '[^a-z0-9]+', ' ', 'g'), '\s+'))
        )
     );
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

REVOKE ALL ON FUNCTION public.aq_link_tevo_from_sibling_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aq_link_tevo_from_sibling_rows() TO service_role;

SELECT cron.schedule(
  'aq_link_tevo_siblings_hourly',
  '50 * * * *',
  $cron$
  SET statement_timeout='120s';
  SELECT public.aq_link_tevo_from_sibling_rows();
  $cron$
);
