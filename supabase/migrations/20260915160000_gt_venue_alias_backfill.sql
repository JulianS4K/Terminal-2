-- Give cross_source_venue_map the GoTickets aliases it is missing, so evo_gt_map can reach stage 1
-- instead of relying on its fuzzy-venue fallback.
--
-- THE GAP. mig 20260915150000 established that cross_source_venue_map is TEvo-complete and
-- GoTickets-sparse: all 1,351 rows carry a tevo_venue_id, but only 484 carry any gotickets alias
-- and only 173 a gotickets_venue_id. Measured at the venue level over the future book:
--
--   TEvo future venues        974   in crosswalk 968 (99.4%)   not in it 6, holding 14 events
--   GoTickets future venues 14,559  in crosswalk 771 ( 5.3%)   not in it 13,788, holding 167,491
--
-- Of 974 TEvo venues holding 7,077 events still unmapped to GoTickets, 535 have NO gotickets alias
-- and hold 1,530 of those events. That is the tractable slice: the venue exists on both sides and
-- only the name differs. Three Broadway houses alone -- St. James, New Amsterdam, Gerald Schoenfeld
-- -- account for 278 unmapped events with GoTickets demonstrably carrying the inventory (1,203, 433
-- and 8 future events respectively at a similar-named venue in the same city).
--
-- WHY THE SIMILARITY NUMBERS LOOKED HOPELESS AT FIRST. cross_source_venue_map.canonical_name is
-- stored NORMALISED -- "newamsterdamtheatre", "geraldschoenfeldtheater" -- so comparing it against
-- GoTickets' spaced "New Amsterdam Theatre" scores 0.62 on trigrams purely for the missing spaces.
-- Normalising both sides the same way moves the same pair to 1.00. The first cut of this analysis
-- read 8 venues above 0.80 and concluded the class was mostly unreachable; with matched
-- normalisation it is 390. The threshold was never the problem, the comparison was.
--
-- WHAT IT MATCHES. Same city AND same state, then trigram similarity on the normalised names at
-- p_min_sim (default 0.75), then BOTH-WAYS uniqueness: exactly one GoTickets venue for the TEvo
-- venue and exactly one TEvo venue for that GoTickets venue.
--
-- The uniqueness test is not ceremony, it is the whole safety argument, because the failure mode
-- here is sub-venues. A complex and its rooms share almost all their words:
--
--   Kiewit Hall / Kiewit CONCERT Hall at Holland Performing Arts Center   2 <-> 2, declined
--   Egyptian Room / MURAT Egyptian Room at Old National Centre            1 <-> 2, declined
--   Allen County War Memorial Coliseum / ARENA at ...                     2 <-> 1, declined
--   Mohawk Austin Outdoor / Indoor                                        2 <-> 1, declined
--
-- A wrong venue alias is worse than a missing one. It feeds evo_gt_map's stage 1, which treats the
-- venue as ANSWERED and drops to a 0.60 name bar on that basis, so a bad alias would quietly
-- license bad event mappings at the highest-confidence stage.
--
-- EVIDENCE FOR 0.75. Every pair in the 0.75-0.95 band was read before the threshold was set, not
-- sampled. They are all the same venue under a different house style -- "&" against "and",
-- "at the" against "at", a "- WA" state suffix, or a word-order swap ("Savannah Civic Center -
-- Johnny Mercer Theatre" against "Johnny Mercer Theatre at Savannah Civic Center"). Nothing in
-- that band was a different venue. Above 0.95 sit 383 essentially-exact pairs.
--
-- SCOPE. 855 crosswalk rows lack a GoTickets alias; 595 have any candidate; 388 survive
-- 0.75 + both-ways uniqueness. The rest are venues GoTickets does not carry, and this migration
-- must not invent them.
--
-- The alias is stored as the RAW gotickets_event.venue_name, because that is what evo_gt_map's
-- _va join compares against (lower(trim(g.venue_name))).
--
-- A BUG THIS FILE SHIPPED WITH AND THEN FIXED, because the dry run made it visible. v1 gathered
-- candidates at p_min_sim and counted uniqueness over THAT pool, which proposed 433. Counting
-- uniqueness over a wider 0.45 pool proposes 388. The 45-row difference is venues that were unique
-- only because raising the threshold had already deleted their competitor -- a manufactured 1:1,
-- and precisely the sub-venue collisions the guard exists to catch. So candidates are gathered at
-- p_rival_floor (0.45) and uniqueness is counted there, while acceptance happens at p_min_sim.
-- It is the same shape as a per-tick cap applied before the predicate that removes finished work:
-- a filter that runs before the test changes what the test can see.
--
-- Dry-run by default. Every write is logged, so it reverses with
--   UPDATE cross_source_venue_map v SET gotickets_aliases = NULL
--     FROM gt_venue_alias_backfill_log l WHERE v.tevo_venue_id = l.tevo_venue_id;

CREATE TABLE IF NOT EXISTS public.gt_venue_alias_backfill_log (
  tevo_venue_id   bigint PRIMARY KEY,
  tevo_venue_name text,
  gt_venue_name   text NOT NULL,
  city            text,
  state           text,
  sim             numeric,
  gt_future_events int,
  added_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.gt_venue_alias_backfill_log IS
  'Every gotickets alias written into cross_source_venue_map by the venue alias backfill. Reversible (mig 20260915160000).';

CREATE OR REPLACE FUNCTION public.gt_venue_alias_backfill(
  p_apply   boolean DEFAULT false,
  p_min_sim numeric DEFAULT 0.75,
  p_rival_floor numeric DEFAULT 0.45
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_written int := 0; v_prop int := 0; v_need int := 0; v_cand int := 0; v_manu int := 0;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _vp (
    tevo_venue_id bigint, tevo_venue_name text, gt_venue_name text,
    city text, st text, sim numeric, gt_events int
  ) ON COMMIT DROP;
  DELETE FROM _vp;

  CREATE TEMP TABLE IF NOT EXISTS _vall (
    tevo_venue_id bigint, disp text, raw text, city text, st text, n int, sim numeric,
    c_for_t int, t_for_c int
  ) ON COMMIT DROP;
  DELETE FROM _vall;

  INSERT INTO _vall
  WITH need AS (
    SELECT v.tevo_venue_id,
           regexp_replace(lower(public.unaccent(coalesce(v.canonical_name, v.tevo_venue_name))),
                          '[^a-z0-9]','','g') AS cnorm,
           coalesce(v.tevo_venue_name, v.canonical_name) AS disp,
           lower(trim(v.city)) AS city, upper(trim(v.state)) AS st
    FROM public.cross_source_venue_map v
    WHERE v.tevo_venue_id IS NOT NULL AND v.city IS NOT NULL AND v.state IS NOT NULL
      AND NOT (jsonb_typeof(v.gotickets_aliases) = 'array'
               AND jsonb_array_length(v.gotickets_aliases) > 0)
  ), gtv AS (
    SELECT min(g.venue_name) AS raw,
           regexp_replace(lower(public.unaccent(g.venue_name)),'[^a-z0-9]','','g') AS gnorm,
           lower(trim(g.venue_city)) AS city, upper(trim(g.venue_state)) AS st, count(*)::int AS n
    FROM public.gotickets_event g
    WHERE g.event_time_utc >= now() AND g.status = 'AS_SCHEDULED'
      AND coalesce(g.venue_name,'') !~* 'parking'
      AND g.venue_name IS NOT NULL AND g.venue_city IS NOT NULL AND g.venue_state IS NOT NULL
    GROUP BY 2,3,4
  )
  SELECT n.tevo_venue_id, n.disp, gtv.raw, n.city, n.st, gtv.n,
         round(similarity(gtv.gnorm, n.cnorm)::numeric,3),
         count(*) OVER (PARTITION BY n.tevo_venue_id)::int,
         count(*) OVER (PARTITION BY gtv.gnorm, gtv.city, gtv.st)::int
  FROM need n
  JOIN gtv ON gtv.city = n.city AND gtv.st = n.st
  WHERE similarity(gtv.gnorm, n.cnorm) >= p_rival_floor;

  INSERT INTO _vp
  SELECT tevo_venue_id, disp, raw, city, st, sim, n
  FROM _vall WHERE sim >= p_min_sim AND c_for_t = 1 AND t_for_c = 1;

  SELECT count(*) INTO v_prop FROM _vp;
  SELECT count(*) INTO v_manu FROM _vall WHERE sim >= p_min_sim AND (c_for_t > 1 OR t_for_c > 1);

  IF p_apply THEN
    WITH w AS (
      UPDATE public.cross_source_venue_map v
         SET gotickets_aliases = jsonb_build_array(p.gt_venue_name), updated_at = now()
        FROM _vp p
       WHERE v.tevo_venue_id = p.tevo_venue_id
         AND NOT (jsonb_typeof(v.gotickets_aliases) = 'array'
                  AND jsonb_array_length(v.gotickets_aliases) > 0)
      RETURNING v.tevo_venue_id
    )
    INSERT INTO public.gt_venue_alias_backfill_log
      (tevo_venue_id, tevo_venue_name, gt_venue_name, city, state, sim, gt_future_events)
    SELECT p.tevo_venue_id, p.tevo_venue_name, p.gt_venue_name, p.city, p.st, p.sim, p.gt_events
    FROM _vp p JOIN w ON w.tevo_venue_id = p.tevo_venue_id
    ON CONFLICT (tevo_venue_id) DO NOTHING;
    GET DIAGNOSTICS v_written = ROW_COUNT;
  END IF;

  SELECT count(*) INTO v_need FROM public.cross_source_venue_map v
   WHERE v.tevo_venue_id IS NOT NULL
     AND NOT (jsonb_typeof(v.gotickets_aliases)='array' AND jsonb_array_length(v.gotickets_aliases)>0);
  SELECT count(*) INTO v_cand FROM public.cross_source_venue_map v
   WHERE jsonb_typeof(v.gotickets_aliases)='array' AND jsonb_array_length(v.gotickets_aliases)>0;

  RETURN jsonb_build_object(
    'applied', p_apply, 'min_sim', p_min_sim, 'rival_floor', p_rival_floor,
    'proposed', v_prop, 'declined_not_unique', v_manu, 'written', v_written,
    'rows_still_without_alias', v_need, 'rows_with_alias', v_cand);
END $fn$;

DROP FUNCTION IF EXISTS public.gt_venue_alias_backfill(boolean, numeric);
REVOKE ALL ON FUNCTION public.gt_venue_alias_backfill(boolean, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gt_venue_alias_backfill(boolean, numeric, numeric) TO service_role;
