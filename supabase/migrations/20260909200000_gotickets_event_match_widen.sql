-- Migration 20260909200000 · level:data-collection · lane:A1 · writes:aq_event_map · reads:s4kcs_orders,events,event_listing_snapshot_daily,gotickets_event,cross_source_venue_map · pre:20260909190000
--
-- Already applied to prod · via MCP 2026-09-09 under operator direction.
-- Verified: filled 68 hub rows on the first run. GoTickets coverage of future
-- events we OWN LISTINGS on: 81.9% -> 83.0% (3,403 of 4,099).
--
-- Three fixes to aq_link_gotickets_by_event_match(). One is a correctness bug.
--
-- ============================================================================
-- 1. BIDIRECTIONAL UNIQUENESS -- this was a real defect, not a tightening.
-- ============================================================================
-- The shipped version required one GT event per TEvo event, but NOT the
-- reverse. TEvo lists a multi-performance run as several events while GoTickets
-- lists one, so N TEvo events could all claim the SAME GT event and every one
-- but a single winner would be wrong. Caught in the dry run:
--
--   "Dolly - A True Original Musical" @ St. James Theatre
--       TEvo 2026-12-26, 2026-12-26, 2026-12-28  ->  ONE GT event, 2026-12-27
--
-- Over the widened candidate set, 11 GT events were being claimed by more than
-- one TEvo event; requiring uniqueness in BOTH directions drops 69 -> 63 and
-- removes the whole class.
--
-- Audited the damage already in the table: 13 gotickets_event_id values are
-- shared by multiple tevo_event_ids (26 hub rows). They are PRE-EXISTING, from
-- GoTickets' own curated feed -- they carry gotickets_map_score values, and the
-- pattern is TEvo listing two performances where GT lists one (Circus Vazquez
-- 16:00 and 19:00 the same day; Disney On Ice 10-30 and 10-31). NONE of them
-- involves the 22 ids this linker wrote, so nothing it has written is affected.
-- They are left alone: deciding which performance owns the GT id is a separate
-- job and the pre-existing rows are not this function's to rewrite.
--
-- ============================================================================
-- 2. CANDIDATE SET WIDENED -- CRM orders were the wrong population.
-- ============================================================================
-- The shipped version joined s4kcs_orders, so it only ever considered events we
-- had SOLD through the CRM. Every event we hold INVENTORY on but have not sold
-- was invisible to it -- a larger set, and the one the 81.9% metric measures.
-- That is why 167 events had a GT event sitting at the right venue and date and
-- were never linked. Candidates are now (CRM orders) UNION (owned listings in
-- the last 30 days).
--
-- ============================================================================
-- 3. EXACT-NAME EQUALITY AS AN ALTERNATIVE TO THE 2-TOKEN FLOOR
-- ============================================================================
-- The >= 2 shared >= 4-char token floor rejects every single-word act:
-- "Juanes" shares exactly one token with "Juanes". Exact normalised equality is
-- now accepted as an alternative arm. It is strictly safer than the token
-- floor -- the strings are identical after casefold/unaccent/strip -- and the
-- venue and date guards still apply.
--
-- ============================================================================
-- PERFORMANCE -- the resolver call had to go.
-- ============================================================================
-- Resolving GT venue strings with cross_source_venue_resolve() per distinct
-- name exceeded the 60s ceiling on the widened set. Venue strings now come from
-- cross_source_venue_map by plain join (gotickets_aliases + tevo_venue_name +
-- crm_aliases), and the GT slice is materialised once into a temp table keyed
-- (vid, date). No per-row function calls.
--
-- WHAT THIS CANNOT FIX. Of the 741 owned-listing events with no GT link,
-- measured 2026-09-09: 574 (77%) have NOTHING in the GoTickets catalogue at
-- that venue on that date -- GoTickets simply does not list them. Only 167
-- were addressable. So the ceiling on that metric is ~86%, not 100%, and the
-- remaining gap is a GoTickets inventory question, not a matching one.
--
-- REVERSIBLE: DROP FUNCTION public.aq_link_gotickets_by_event_match();
-- (re-apply mig 20260909190000 for the previous definition).

-- Full body applied in prod as authored this session. The three changes vs
-- mig 20260909190000 are marked inline below.

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

  -- CHANGE 2: candidates are anything we have a commercial stake in. CRM orders
  -- alone missed every event we hold INVENTORY on but have not sold.
  DROP TABLE IF EXISTS _gt_need;
  CREATE TEMP TABLE _gt_need ON COMMIT DROP AS
  WITH have AS (
    SELECT DISTINCT tevo_event_id FROM public.aq_event_map
     WHERE tevo_event_id IS NOT NULL AND gotickets_event_id IS NOT NULL
  ), want AS (
    SELECT DISTINCT o.tevo_event_id AS id
      FROM public.s4kcs_orders o
     WHERE o.event_date >= current_date AND o.tevo_event_id IS NOT NULL
    UNION
    SELECT DISTINCT d.event_id
      FROM public.event_listing_snapshot_daily d
     WHERE d.snapshot_date >= current_date - 30
       AND coalesce(d.evo_owned_tickets,0) > 0
  )
  SELECT e.id AS tevo_event_id, e.name, e.venue_id, left(e.occurs_at_local,10)::date AS d
    FROM want w JOIN public.events e ON e.id = w.id
   WHERE left(e.occurs_at_local,10)::date >= current_date
     AND e.id NOT IN (SELECT tevo_event_id FROM have);
  CREATE INDEX ON _gt_need (venue_id, d);
  ANALYZE _gt_need;

  -- PERFORMANCE: venue strings from the MAP by plain join. Calling
  -- cross_source_venue_resolve() per distinct GT venue name exceeded 60s.
  DROP TABLE IF EXISTS _gt_venues;
  CREATE TEMP TABLE _gt_venues ON COMMIT DROP AS
  SELECT DISTINCT m.tevo_venue_id AS vid, x.alias AS gt_venue_name
    FROM public.cross_source_venue_map m
    CROSS JOIN LATERAL (
      SELECT jsonb_array_elements_text(m.gotickets_aliases) AS alias
      UNION SELECT m.tevo_venue_name
      UNION SELECT jsonb_array_elements_text(m.crm_aliases)
    ) x
   WHERE m.tevo_venue_id IN (SELECT DISTINCT venue_id FROM _gt_need)
     AND x.alias IS NOT NULL;
  CREATE INDEX ON _gt_venues (gt_venue_name);
  ANALYZE _gt_venues;

  DROP TABLE IF EXISTS _gt_cand;
  CREATE TEMP TABLE _gt_cand ON COMMIT DROP AS
  SELECT v.vid, g.gt_event_id, g.name, g.venue_name, g.event_time_utc::date AS gd
    FROM _gt_venues v
    JOIN public.gotickets_event g ON g.venue_name = v.gt_venue_name
   WHERE g.status IS DISTINCT FROM 'cancelled'
     AND g.event_time_utc >= current_date - 2;
  CREATE INDEX ON _gt_cand (vid, gd);
  ANALYZE _gt_cand;

  DROP TABLE IF EXISTS _gt_pair;
  CREATE TEMP TABLE _gt_pair ON COMMIT DROP AS
  SELECT o.tevo_event_id, c.gt_event_id
    FROM _gt_need o
    JOIN _gt_cand c ON c.vid = o.venue_id AND c.gd BETWEEN o.d - 1 AND o.d + 1
   WHERE o.name !~* 'season tickets?' AND c.name !~* 'season tickets?'
     AND o.name NOT ILIKE '%parking%' AND c.name NOT ILIKE '%parking%'
     AND o.name !~* 'camping|grandstand|grounds admission|pass only'
     AND c.name !~* 'camping|grandstand|grounds admission|pass only'
     AND c.venue_name !~* 'camping|grandstand'
     AND c.name !~* '^cancelled'
     AND ((o.name !~* 'session\s*\d+' OR c.name !~* 'session\s*\d+')
          OR (regexp_match(lower(o.name),'session\s*(\d+)'))[1]
           = (regexp_match(lower(c.name),'session\s*(\d+)'))[1])
     AND public.aq_name_consistent(public.unaccent(c.name), public.unaccent(o.name))
     -- CHANGE 3: exact normalised equality OR the >= 2 token floor. The floor
     -- alone rejects every single-word act ("Juanes" shares one token).
     AND (regexp_replace(lower(public.unaccent(o.name)),'[^a-z0-9]+','','g')
        = regexp_replace(lower(public.unaccent(c.name)),'[^a-z0-9]+','','g')
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(o.name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(c.name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           ) q(tok) WHERE length(tok) >= 4) >= 2);

  -- CHANGE 1 (the bug fix): BIDIRECTIONAL uniqueness. One-way let three "Dolly -
  -- A True Original Musical" performances all claim one GT event.
  UPDATE public.aq_event_map m
     SET gotickets_event_id = ok.gt_event_id
    FROM (
      SELECT p.tevo_event_id, min(p.gt_event_id) AS gt_event_id
        FROM _gt_pair p
       WHERE p.tevo_event_id IN (SELECT tevo_event_id FROM _gt_pair
                                  GROUP BY 1 HAVING count(DISTINCT gt_event_id) = 1)
         AND p.gt_event_id   IN (SELECT gt_event_id   FROM _gt_pair
                                  GROUP BY 1 HAVING count(DISTINCT tevo_event_id) = 1)
       GROUP BY 1
    ) ok
   WHERE m.tevo_event_id = ok.tevo_event_id
     AND m.gotickets_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;
REVOKE ALL ON FUNCTION public.aq_link_gotickets_by_event_match() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aq_link_gotickets_by_event_match() TO service_role;
