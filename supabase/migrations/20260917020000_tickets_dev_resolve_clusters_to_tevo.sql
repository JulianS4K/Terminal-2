-- Migration 20260917020000 · level:data-collection · lane:A1 · writes:tickets_dev_resolve_clusters_to_tevo() fn (new), tickets_dev_run() fn (+1 PERFORM), gotickets_event.tevo_event_id (fill-only) · reads:tickets_dev_event, tickets_dev_source_id, gotickets_event, events · pre:20260917010000
--
-- ============================================================================================
-- THE HUB CANNOT RESOLVE A CLUSTER WHOSE SIBLINGS IT HAS NEVER SEEN. THE TEVO MIRROR CAN.
-- ============================================================================================
-- Eight hours of the catalogue drain (mig 20260916220000) produced +2,665 clusters and +6,690
-- marketplace ids -- and ONE organic GoTickets -> TEvo mapping. The reason was measured on the
-- first sample and held all night: hub_backfill resolves a cluster through aq_event_map, and
-- the Vivid/StubHub/TM ids the drain brings in are ids the hub has never ingested, so it has
-- nothing to resolve them against. The chain was cluster -> hub -> TEvo, and the middle link
-- is empty for exactly the population the drain reaches.
--
-- Operator 2026-09-17: "Do it."
--
-- THIS GOES AROUND THE HUB: cluster -> TEvo mirror directly, by venue id + local day + name.
--   1. the cluster's venue string -> tevo venue id via cross_source_venue_resolve (the same
--      resolver s4kcs_map_events uses for its venue-id tier)
--   2. events at that venue, state = 'shown', occurs_at_local on the cluster's local_date
--      (tickets.dev local_date is a TRUE local day, mig 20260914211000 -- no UTC shift here)
--   3. EXACTLY ONE candidate passing the name rules copied verbatim from
--      gotickets_backfill_tevo_from_hub: aq_name_consistent, the "session N" number guard,
--      the parking / grounds-pass / season-ticket exclusions
--   4. write gotickets_event.tevo_event_id for the cluster's GoTickets member, fill-only, with
--      BOTH halves of the both-ways guard (no other GoTickets row already claims that TEvo
--      event; no two candidates in this statement want the same TEvo event)
--
-- Only gotickets_event is written. The hub follows on its own: hub_backfill's resolution UNIONs
-- gotickets_event.tevo_event_id into the cluster's reachable TEvo set, so the next tick enriches
-- aq_event_map with the cluster's siblings, and the linkers fill the CRM after that. One write
-- at the root of the chain, the rest is the existing machinery.
--
-- MEASURED BEFORE WRITING, population-wide, not the earlier 189-event sample:
--   clusters carrying an unmapped GoTickets event     2,517
--   venue TEvo cannot resolve                          2,169   (86%) -- TEvo does not carry it
--   venue resolves, no TEvo event that day               290
--   EXACTLY ONE name-consistent candidate                 33   <- this migration's yield today
--     of which the TEvo event is already claimed           1   (refused by the guard)
--   several name-consistent candidates                     9   (refused: ambiguous)
--   name guard fails                                      16   (refused: wrong event)
-- ~32 today, ~1.3% of clusters. Small and honest; it compounds as the drain runs, and the
-- alternative is the zero the hub route produces on this population.
--
-- mapped_via = 'tdev_venue_day' so these rows are distinguishable from hub-derived and
-- GoTickets-asserted mappings, and reversible by marker like every other route.
-- ============================================================================================

CREATE OR REPLACE FUNCTION public.tickets_dev_resolve_clusters_to_tevo(
  p_apply boolean DEFAULT false,
  p_limit int     DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_cap        int;
  v_candidates int := 0;
  v_venue_null int := 0;
  v_none       int := 0;
  v_one        int := 0;
  v_several    int := 0;
  v_name_fail  int := 0;
  v_claimed    int := 0;
  v_written    int := 0;
  v_started    timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);
  v_cap := greatest(1, least(2000, coalesce(p_limit, 200)));

  -- clusters whose GoTickets member is unmapped, nearest first (a mapping for next week is worth
  -- more than one for next spring, same ordering as the catalogue seed)
  DROP TABLE IF EXISTS _tdr;
  CREATE TEMP TABLE _tdr ON COMMIT DROP AS
  SELECT e.tdev_id, e.name, e.local_date, g.gt_event_id,
         public.cross_source_venue_resolve(e.venue_name, e.venue_city, e.venue_state) AS vid
    FROM public.tickets_dev_event e
    JOIN public.tickets_dev_source_id s ON s.tdev_id = e.tdev_id AND s.marketplace = 'gotickets'
    JOIN public.gotickets_event g ON g.gt_event_id::text = s.source_event_id AND g.tevo_event_id IS NULL
   WHERE e.local_date >= current_date
     AND coalesce(e.name, '') !~* 'parking|shuttle|camping|grandstand|grounds admission|grounds pass|pass only|season tickets?'
   ORDER BY e.local_date
   LIMIT v_cap;
  SELECT count(*), count(*) FILTER (WHERE vid IS NULL) INTO v_candidates, v_venue_null FROM _tdr;

  -- the one TEvo event at that venue on that local day that the name rules accept -- or nothing
  DROP TABLE IF EXISTS _tdm;
  CREATE TEMP TABLE _tdm ON COMMIT DROP AS
  SELECT t.tdev_id, t.gt_event_id, t.name AS gt_name,
         count(ev.id) AS same_day,
         count(ev.id) FILTER (WHERE
               ev.name NOT ILIKE '%parking%'
           AND ev.name !~* 'camping|grandstand|grounds admission|grounds pass|pass only|season tickets?'
           AND ((ev.name !~* 'session\s*\d+' OR t.name !~* 'session\s*\d+')
                OR (regexp_match(lower(ev.name), 'session\s*(\d+)'))[1] = (regexp_match(lower(t.name), 'session\s*(\d+)'))[1])
           AND public.aq_name_consistent(public.unaccent(ev.name), public.unaccent(t.name))) AS name_ok,
         min(ev.id) FILTER (WHERE
               ev.name NOT ILIKE '%parking%'
           AND ev.name !~* 'camping|grandstand|grounds admission|grounds pass|pass only|season tickets?'
           AND ((ev.name !~* 'session\s*\d+' OR t.name !~* 'session\s*\d+')
                OR (regexp_match(lower(ev.name), 'session\s*(\d+)'))[1] = (regexp_match(lower(t.name), 'session\s*(\d+)'))[1])
           AND public.aq_name_consistent(public.unaccent(ev.name), public.unaccent(t.name))) AS tevo_event_id
    FROM _tdr t
    LEFT JOIN public.events ev
      ON ev.venue_id = t.vid AND ev.state = 'shown'
     AND left(ev.occurs_at_local, 10)::date = t.local_date
   WHERE t.vid IS NOT NULL
   GROUP BY t.tdev_id, t.gt_event_id, t.name;

  SELECT count(*) FILTER (WHERE same_day = 0),
         count(*) FILTER (WHERE name_ok = 1),
         count(*) FILTER (WHERE name_ok > 1),
         count(*) FILTER (WHERE same_day > 0 AND name_ok = 0),
         count(*) FILTER (WHERE name_ok = 1 AND EXISTS (SELECT 1 FROM public.gotickets_event g2
                             WHERE g2.tevo_event_id = _tdm.tevo_event_id AND g2.gt_event_id <> _tdm.gt_event_id))
    INTO v_none, v_one, v_several, v_name_fail, v_claimed
    FROM _tdm;

  IF NOT p_apply THEN
    RETURN jsonb_build_object(
      'applied', false, 'note', 'DRY RUN -- nothing written.',
      'candidates', v_candidates, 'venue_unresolved', v_venue_null, 'no_tevo_that_day', v_none,
      'would_write', v_one - v_claimed, 'refused', jsonb_build_object(
        'several_candidates', v_several, 'name_guard', v_name_fail, 'tevo_already_claimed', v_claimed),
      'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
  END IF;

  -- BOTH HALVES of the both-ways guard: half one drops any TEvo event wanted by two candidates
  -- in this statement (a NOT EXISTS cannot see them -- proven on prod 2026-09-16); half two
  -- refuses a TEvo event another GoTickets row already holds.
  WITH ok AS (
    SELECT gt_event_id, tevo_event_id FROM _tdm WHERE name_ok = 1
  ), ok1 AS (
    SELECT * FROM ok WHERE tevo_event_id IN (SELECT tevo_event_id FROM ok GROUP BY 1 HAVING count(*) = 1)
  )
  UPDATE public.gotickets_event g
     SET tevo_event_id = ok.tevo_event_id, mapped_via = 'tdev_venue_day', mapped_at = now()
    FROM ok1 ok
   WHERE g.gt_event_id = ok.gt_event_id
     AND g.tevo_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2
                      WHERE g2.tevo_event_id = ok.tevo_event_id AND g2.gt_event_id <> ok.gt_event_id);
  GET DIAGNOSTICS v_written = ROW_COUNT;

  RETURN jsonb_build_object(
    'applied', true,
    'candidates', v_candidates, 'venue_unresolved', v_venue_null, 'no_tevo_that_day', v_none,
    'written', v_written, 'refused', jsonb_build_object(
      'several_candidates', v_several, 'name_guard', v_name_fail, 'tevo_already_claimed', v_claimed),
    'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_resolve_clusters_to_tevo(boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_resolve_clusters_to_tevo(boolean, int) TO service_role;

COMMENT ON FUNCTION public.tickets_dev_resolve_clusters_to_tevo(boolean, int) IS
  'Maps a tickets.dev cluster''s unmapped GoTickets event to TEvo DIRECTLY -- venue id + local day + the hub-backfill name rules -- for the population whose siblings the hub has never seen. Exactly-one candidate or nothing; fill-only; both halves of the both-ways guard; mapped_via = tdev_venue_day. Writes only gotickets_event; the hub and the linkers follow on the next tick. DRY RUN unless p_apply => true (mig 20260917020000).';

-- ---------------------------------------------------------------- into the tick
-- The 20260916220000 body verbatim plus ONE line after step 3. Nothing else changes.
CREATE OR REPLACE FUNCTION public.tickets_dev_run(p_limit int DEFAULT 120)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_h jsonb; v_b jsonb; v_gt_evo int := 0; v_direct jsonb; v_v int := 0; v_g int := 0; v_c int := 0; v_ask int := 0; v_cap int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  v_cap := greatest(1, least(500, coalesce(p_limit, 120)));

  v_h := public.tickets_dev_harvest();
  v_b := public.tickets_dev_hub_backfill();
  -- Step 3 of the chain, in the tick for the first time: a cluster harvested this tick maps its
  -- GoTickets row to TEvo this tick. Guarded, fill-only, both-ways (see the header).
  v_gt_evo := public.gotickets_backfill_tevo_from_hub();
  -- Step 3b (mig 20260917020000): the direct route for clusters the hub cannot resolve.
  v_direct := public.tickets_dev_resolve_clusters_to_tevo(true, v_cap);

  -- SEED 1 -- Vivid productions we hold unmapped orders on. Unchanged.
  SELECT public.tickets_dev_probe_enqueue('vividseats', array_agg(id)) INTO v_v FROM (
    SELECT DISTINCT raw->>'productionId' AS id, min(event_date) AS d
      FROM public.vivid_orders
     WHERE tevo_event_id IS NULL AND raw->>'productionId' ~ '^[0-9]+$'
       AND event_date > now() AND event_name !~* 'parking|shuttle'
     GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;

  -- SEED 2 -- GoTickets events we hold unmapped purchases on. Unchanged, and still first among
  -- the GoTickets seeds: a row we have money on outranks one we do not.
  SELECT public.tickets_dev_probe_enqueue('gotickets', array_agg(id)) INTO v_g FROM (
    SELECT DISTINCT gt_event_id::text AS id, min(event_time_local) AS d
      FROM public.gotickets_purchases
     WHERE tevo_event_id IS NULL AND gt_event_id IS NOT NULL
       AND event_time_local > now() AND coalesce(event_name,'') !~* 'parking|shuttle'
     GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;

  -- SEED 3 -- NEW: the GoTickets catalogue itself. Every future, live, unmapped event, nearest
  -- first. askable() is applied BEFORE the limit (the 20260915011000 starvation lesson); the
  -- 7-day not_found retry and the never-retry source_not_indexed rule both live inside it.
  SELECT public.tickets_dev_probe_enqueue('gotickets', array_agg(id)) INTO v_c FROM (
    SELECT g.gt_event_id::text AS id
      FROM public.gotickets_event g
     WHERE g.tevo_event_id IS NULL
       AND g.event_time_utc > now()
       AND coalesce(g.status, '') NOT IN ('CANCELLED', 'MERGED')
       AND coalesce(g.name, '') !~* 'parking|shuttle'
       AND public.tickets_dev_askable('gotickets', g.gt_event_id::text)
     ORDER BY g.event_time_utc
     LIMIT v_cap) q;

  -- what is left, so a future starvation is visible in the tick's own return value
  SELECT count(*) INTO v_ask
    FROM public.gotickets_event g
   WHERE g.tevo_event_id IS NULL AND g.event_time_utc > now()
     AND coalesce(g.status, '') NOT IN ('CANCELLED', 'MERGED')
     AND coalesce(g.name, '') !~* 'parking|shuttle'
     AND public.tickets_dev_askable('gotickets', g.gt_event_id::text);

  RETURN jsonb_build_object('harvest', v_h, 'backfill', v_b, 'gt_mapped_to_tevo', v_gt_evo,
                            'direct_resolve', v_direct,
                            'enqueued', jsonb_build_object('vividseats', coalesce(v_v,0),
                                                           'gotickets_purchases', coalesce(v_g,0),
                                                           'gotickets_catalogue', coalesce(v_c,0)),
                            'catalogue_askable_remaining', v_ask);
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_run(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_run(int) TO service_role;

COMMENT ON FUNCTION public.tickets_dev_run(int) IS
  'tickets.dev bridge tick: harvest settled probes, enrich the hub from clusters, map GoTickets rows to TEvo from the hub (both-ways guarded, fill-only), then DIRECTLY by venue id + local day for clusters the hub cannot resolve (mig 20260917020000), then enqueue the next batch from three seeds -- Vivid orders, GoTickets purchases, and the GoTickets catalogue itself, nearest first, askable-before-limit. GET-only (RULE 2).';

-- ============================================================================================
-- APPLIED AND VERIFIED ON PROD, 2026-09-17 00:xx
-- ============================================================================================
-- Dry run and apply over the nearest 2,000 candidates returned the same numbers:
--   venue unresolved     1,847     no TEvo event that day   117
--   WRITTEN                 25     refused: several 2 · name guard 9 · already claimed 0
--
-- ALL 25 READ AS REAL MATCHES on inspection: same venue, same local day, single claimant each,
-- double-claims 235 before and after. The GoTickets date sits one day ahead of TEvo's local
-- date on the evening shows -- GoTickets stores UTC, tickets.dev's local_date drove the match,
-- and that is the standard shift, not a miss (the same shape as the Nebraska volleyball case).
--
-- TWO SOFT MATCHES, NAMED RATHER THAN HIDDEN, because the name guard let them through on
-- shared tokens and a reviewer should see what "consistent" means in practice:
--   * "I see Stars with Nate Vickers" -> TEvo "Nate Vickers"   -- TEvo bills the support act;
--     same room, same night, one event. Correct, but on a thin thread.
--   * "Jurassic Quest" -> TEvo "Jurassic Quest (Multiple Dates and Times)"   -- TEvo's catch-all
--     row for a multi-day run. The single candidate on that day IS that row.
-- Neither is wrong; both are the kind of thing an operator would rather know about.
--
-- 25 today, from a population of 2,517 unmapped-GoTickets clusters; it runs every tick from
-- here (tickets_dev_run, after the hub backfill) and compounds as the drain grows. The 1,847 at
-- venues TEvo cannot resolve are not this function's to reach -- they are the TEvo-absent class,
-- and for them the cluster's marketplace identity is the payload.
--
-- CORRECTION, MEASURED AFTER THE FIRST RUN: the header says "the hub and the linkers follow on
-- the next tick". That is true only where a hub row exists, because hub_backfill UPDATEs
-- aq_event_map and never INSERTs. Of the 25 written, exactly 1 TEvo event has an aq_event_map
-- row at all, 1 is on a CRM order, 0 are events we have transacted on. So for 24 of 25 the hub
-- step is a no-op -- the mapping still reaches the CRM/N2S linkers (spine route, reads
-- gotickets_event directly) and the event page's GoTickets chip (same), but nothing enriches
-- the hub. That is what nearest-first residue at small venues looks like, and it is what the
-- 86%-unresolvable-venue number said to expect. Left as written; the route is correct and
-- cheap, and its value grows with the drain rather than sitting in these 25.
