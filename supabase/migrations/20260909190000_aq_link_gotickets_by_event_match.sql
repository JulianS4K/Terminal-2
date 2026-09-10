-- Migration 20260909190000 · level:data-collection · lane:A1 · writes:aq_event_map · reads:s4kcs_orders,events,gotickets_event,cross_source_venue_map · pre:20260909180000
--
-- Already applied to prod · via MCP 2026-09-09 under operator direction.
-- Verified: aq_link_gotickets_by_event_match() returns 0 (idempotent -- its 22
-- links were applied by hand earlier the same day); re-running the identical
-- body WITHOUT the already-linked exclusion re-finds 852 unique pairs, proving
-- the matcher fires and the 0 is idempotence, not a broken join. Wired into
-- tevo_venue_daily_harvest() and reported in the daily bot_chat ping.
--
-- Persists the second, opposite-direction GoTickets linker. There are now two,
-- and the distinction matters:
--
--   aq_link_gotickets_from_catalogue()  (mig 20260909021500)
--       TRUSTS gotickets_event.tevo_event_id and copies it onto the hub.
--       Only reaches the 4,641 of 228,102 catalogue rows GT has mapped itself.
--
--   aq_link_gotickets_by_event_match()  (this migration)
--       DERIVES the link where the catalogue has NO tevo_event_id of its own --
--       160,427 future GT events, 97.4% of the catalogue. Matches our `events`
--       mirror to GT on resolved venue + date + name, and never reads GT's
--       tevo_event_id at all.
--
-- WHY IT EXISTS. Measured 2026-09-09: 368 future events had CRM orders but no
-- GT id, carrying 3,297 orders. from_catalogue() could not touch them -- GT had
-- never mapped its own rows. This matched 22 of the 368 (an 8% yield, because
-- GoTickets genuinely does not list most of that long tail) covering 256 orders.
--
-- ⚠ THE GUARDS ARE NOT OPTIONAL -- THE FIRST DRY RUN PRODUCED 6 FALSE MATCHES.
-- They were caught in the dry run and never written, but only because the run
-- was read row by row. What the first, under-guarded attempt bound:
--
--   "Jack Johnson with Hermanos Gutierrez and G. Love"
--        -> "Jack Johnson Camping - 3 Day Pass (9/25 - 9/27)"
--           @ venue "Gorge Amphitheatre Camping"        (a CAMPING PASS)
--   "Big Ten Volleyball Tournament - Session 2"  -> "... - Session 1"
--   "Big Ten Volleyball Tournament - Session 3"  -> "... - Session 1"
--   "Miami Open Tennis - Session 5"   -> "Miami Open Tennis - Grandstand Session 2"
--   "Miami Open Tennis - Session 18"  -> "... - Grandstand Session 17"
--   "Miami Open Tennis - Session 19"  -> "... - Grandstand Session 17"
--
-- So three guard families are load-bearing, and all three already existed in
-- from_catalogue() -- the first attempt simply failed to reuse them:
--   1. session-number EQUALITY when both names carry "session N"
--   2. camping / grandstand / grounds-admission / "pass only" exclusion, on
--      BOTH names and on the GT venue string. These are non-ticket products and
--      sub-venues, the same class as the parking guard.
--   3. season-ticket + parking exclusion on both sides.
-- Plus aq_name_consistent() and a >= 2 shared >= 4-char token floor, then a
-- uniqueness gate: exactly ONE GT event may survive per TEvo event.
--
-- DATE TOLERANCE is +/- 1.5 days on purpose: gotickets_event.event_time_utc is
-- UTC while events.occurs_at_local is local, so a correct pair legitimately sits
-- a day apart (PROJECT_BIBLE §3 mixed-timezone landmine).
--
-- PERFORMANCE. GT venue strings are resolved ONCE into a temp table, restricted
-- to venues appearing on a date we actually need -- 228k catalogue rows through
-- cross_source_venue_resolve() per candidate would never finish. Measured 1,577
-- distinct venues for the 368-event working set.
--
-- Existing gotickets_event_id values are NEVER overwritten (gated on IS NULL),
-- so the 23 known hub/catalogue conflicts stay untouched.
--
-- REVERSIBLE: the links are indistinguishable from any other gotickets_event_id
-- once written, so revert by dropping the function and, if needed, clearing the
-- ids for the affected events from the run's own record.
--   DROP FUNCTION public.aq_link_gotickets_by_event_match();

CREATE OR REPLACE FUNCTION public.aq_link_gotickets_by_event_match()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'aq_link_gotickets_by_event_match: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;

  DROP TABLE IF EXISTS _gt_need;
  CREATE TEMP TABLE _gt_need ON COMMIT DROP AS
  WITH have AS (
    SELECT DISTINCT tevo_event_id FROM public.aq_event_map
     WHERE tevo_event_id IS NOT NULL AND gotickets_event_id IS NOT NULL
  )
  SELECT DISTINCT o.tevo_event_id, e.name, e.venue_id, left(e.occurs_at_local,10)::date AS d
    FROM public.s4kcs_orders o
    JOIN public.events e ON e.id = o.tevo_event_id
   WHERE o.event_date >= current_date
     AND o.tevo_event_id IS NOT NULL
     AND o.tevo_event_id NOT IN (SELECT tevo_event_id FROM have);
  CREATE INDEX ON _gt_need (venue_id, d);
  ANALYZE _gt_need;

  -- Resolve GT venue strings ONCE, restricted to dates we need: 228k catalogue
  -- rows through cross_source_venue_resolve() per candidate would never finish.
  DROP TABLE IF EXISTS _gt_venues;
  CREATE TEMP TABLE _gt_venues ON COMMIT DROP AS
  SELECT v_raw, public.cross_source_venue_resolve(split_part(v_raw,' - ',1), NULL, st) AS vid
    FROM (SELECT DISTINCT g.venue_name AS v_raw,
                 nullif(upper(trim(g.venue_state)),'') AS st
            FROM public.gotickets_event g
           WHERE g.tevo_event_id IS NULL
             AND g.status IS DISTINCT FROM 'cancelled'
             AND g.venue_name IS NOT NULL
             AND g.event_time_utc::date IN (SELECT d FROM _gt_need)) u;
  DELETE FROM _gt_venues WHERE vid IS NULL;
  CREATE INDEX ON _gt_venues (v_raw);
  ANALYZE _gt_venues;

  DROP TABLE IF EXISTS _gt_pair;
  CREATE TEMP TABLE _gt_pair ON COMMIT DROP AS
  SELECT n2.tevo_event_id, g.gt_event_id
    FROM _gt_need n2
    JOIN _gt_venues r ON r.vid = n2.venue_id
    JOIN public.gotickets_event g
      ON g.venue_name = r.v_raw
     AND g.tevo_event_id IS NULL
     AND g.status IS DISTINCT FROM 'cancelled'
     -- +/- 1.5 days: GT stores UTC, occurs_at_local is local (§3 landmine).
     AND abs(EXTRACT(epoch FROM (g.event_time_utc - n2.d::timestamptz))/86400.0) <= 1.5
   WHERE n2.name !~* 'season tickets?' AND g.name !~* 'season tickets?'
     AND n2.name NOT ILIKE '%parking%' AND g.name NOT ILIKE '%parking%'
     -- Non-ticket products and sub-venues. Without this a Jack Johnson CONCERT
     -- binds to "Jack Johnson Camping - 3 Day Pass" @ "Gorge Amphitheatre
     -- Camping", and Miami Open sessions bind to Grandstand sessions.
     AND n2.name !~* 'camping|grandstand|grounds admission|pass only'
     AND g.name  !~* 'camping|grandstand|grounds admission|pass only'
     AND g.venue_name !~* 'camping|grandstand'
     -- Session numbers must agree: without it "Big Ten Volleyball Tournament -
     -- Session 2" AND "- Session 3" both bound to Session 1.
     AND ((n2.name !~* 'session\s*\d+' OR g.name !~* 'session\s*\d+')
          OR (regexp_match(lower(n2.name),'session\s*(\d+)'))[1]
           = (regexp_match(lower(g.name), 'session\s*(\d+)'))[1])
     AND public.aq_name_consistent(public.unaccent(g.name), public.unaccent(n2.name))
     AND (SELECT count(*) FROM (
           SELECT unnest(string_to_array(trim(regexp_replace(lower(
                    regexp_replace(public.unaccent(n2.name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           INTERSECT
           SELECT unnest(string_to_array(trim(regexp_replace(lower(
                    regexp_replace(public.unaccent(g.name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
         ) q(tok) WHERE length(tok) >= 4) >= 2;

  -- Exactly ONE GT event may survive per TEvo event.
  UPDATE public.aq_event_map m
     SET gotickets_event_id = ok.gt_event_id
    FROM (SELECT tevo_event_id, min(gt_event_id) AS gt_event_id
            FROM _gt_pair GROUP BY 1
          HAVING count(DISTINCT gt_event_id) = 1) ok
   WHERE m.tevo_event_id = ok.tevo_event_id
     AND m.gotickets_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;
REVOKE ALL ON FUNCTION public.aq_link_gotickets_by_event_match() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aq_link_gotickets_by_event_match() TO service_role;

-- tevo_venue_daily_harvest() now calls BOTH GoTickets linkers after
-- s4kcs_map_events() -- newly-mapped events are new candidates for a GT link --
-- and reports each count in the daily ping. Full body applied in prod as
-- authored this session.
