-- Migration 20260916220000 · level:data-collection · lane:A1 · writes:tickets_dev_run() fn, gotickets_backfill_tevo_from_hub() fn (both-ways guard) · reads:gotickets_event, tickets_dev_probe · pre:20260916200000
--
-- ============================================================================================
-- THE CATALOGUE WAS STARVED BY ITS OWN SEEDING RULE
-- ============================================================================================
-- tickets_dev_run() asked tickets.dev only about GoTickets events we had BOUGHT on and failed
-- to map (gotickets_purchases), and Vivid productions we had ORDERS on (vivid_orders). Both are
-- order-driven tails: the queue drains the moment our unmapped orders run out, and it had --
-- cron 652 fired every 15 minutes and succeeded every time while enqueuing 103 probes a day.
--
--   GoTickets future events                          195,809
--   ever probed                                        3,763   (1.9%)
--   future, unmapped to TEvo, NEVER ASKED            167,448
--
-- Operator 2026-09-16: "use that method to map other marketplaces to gotix and then map go to
-- Evo and use the other functions for stragglers."
--
-- THE CHAIN ALREADY EXISTS; ONLY THE INWARD SEED WAS MISSING.
--   1. tickets_dev_harvest      cluster + one id per marketplace  -> tickets_dev_source_id
--                                (this IS "other marketplaces -> GoTickets": an identity, never a pick)
--   2. tickets_dev_hub_backfill  cluster siblings -> aq_event_map, only where they resolve to ONE TEvo
--   3. gotickets_backfill_tevo_from_hub  aq_event_map.gotickets_event_id -> gotickets_event.tevo_event_id
--                                (this is "GoTickets -> EVO", mapped_via = 'hub_backfill')
--   4. evo_gt_pipeline_tick / event_mapper_*  the stragglers, unchanged
--
-- Step 3 was applied ONCE on 2026-09-09 and never scheduled -- no cron calls it. So a harvested
-- cluster enriched the hub and the catalogue row stayed unmapped. It now runs in the tick,
-- directly after step 2, so a GoTickets event asked about at :08 is mapped to TEvo at :08.
--
-- WHY THIS IS SAFE WHERE "CLUSTER AS HUB" WAS NOT (the 9-conflict test earlier today): nothing
-- here picks a TEvo event for a cluster. Step 2 refuses unless exactly one TEvo is reachable,
-- step 3 refuses unless exactly one TEvo is reachable AND the names agree, and both are
-- fill-only. A cluster that spans two nights (the J Cole / Dodgers / Cubs collisions) resolves
-- to two TEvo events and is left alone by both.
--
-- THE BOTH-WAYS GUARD, ADDED TO STEP 3 -- IN TWO HALVES, BECAUSE THE FIRST RUN PROVED ONE IS NOT
-- ENOUGH. Half two (NOT EXISTS against existing rows) went in first; on its first prod run it let
-- two nights of 'Usher and Chris Brown' both stamp TEvo 3366101 at the same instant, because a
-- NOT EXISTS sees the statement-start snapshot and neither row existed yet. Half one (the ok1
-- CTE) drops any TEvo wanted by two candidates in the same statement. The two bad rows were
-- reverted by their provenance marker; double-claims back to 235.
--
-- The original half-two note: It guarded GoTickets -> many TEvo (HAVING count(DISTINCT)
-- = 1) but not TEvo -> many GoTickets. Run once by hand that was tolerable; run every fifteen
-- minutes it would quietly regrow the 235 double-claims that 20260915260000 put a guard on in
-- the pipeline template. The identical NOT EXISTS is added here. One line, same semantics.
--
-- COST: none. /v1/events is the free GET endpoint (RULE 2, mig 20260914211000); tickets_dev_askable
-- is the do-not-ask-twice gate and is applied BEFORE the limit, which is the starvation lesson
-- from 20260915011000 -- a cap applied first lands on the oldest ids, which are exactly the ones
-- already asked. Nearest event first, because a probe answered for a show next week is worth
-- more than one for a show next spring. CANCELLED and MERGED rows are never asked about.
--
-- THROUGHPUT: cap 150 per tick x 96 ticks/day = 14,400/day for the catalogue seed alone, so the
-- 106,267 askable rows drain in ~8 days; the purchase and Vivid seeds keep their place ahead of
-- it because a row we hold an order on is worth more than one we do not.
-- ============================================================================================

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
     -- launders known-bad pairings into the catalogue. See 20260909210000 for
     -- the two classes this caught (US Open grounds-pass, season-ticket -> single game).
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
  ), ok1 AS (
    -- BOTH-WAYS GUARD, HALF ONE (mig 20260916220000): a TEvo event wanted by TWO candidate
    -- GoTickets rows in this same statement is dropped for both. The NOT EXISTS below cannot
    -- catch this case -- it reads a statement-start snapshot in which neither row is written yet,
    -- so both pass and both land. First run on prod did exactly that: two nights of one show
    -- stamped to one TEvo event at the identical instant. This CTE is the fix.
    SELECT * FROM ok
     WHERE tevo_event_id IN (SELECT tevo_event_id FROM ok GROUP BY 1 HAVING count(*) = 1)
  )
  UPDATE public.gotickets_event g
     SET tevo_event_id = ok.tevo_event_id,
         mapped_via = 'hub_backfill',   -- provenance: derived, not GT-asserted
         mapped_at  = now()
    FROM ok1 ok
   WHERE g.gt_event_id = ok.gt_event_id
     AND g.tevo_event_id IS NULL        -- never overwrite
     -- BOTH-WAYS GUARD, HALF TWO: the TEvo event must not ALREADY be claimed by a different
     -- GoTickets row. Same line as the pipeline template in 20260915260000; without it a
     -- 15-minute cadence regrows the double-claims that guard exists to stop.
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2
                      WHERE g2.tevo_event_id = ok.tevo_event_id AND g2.gt_event_id <> ok.gt_event_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;
REVOKE ALL ON FUNCTION public.gotickets_backfill_tevo_from_hub() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gotickets_backfill_tevo_from_hub() TO service_role;

CREATE OR REPLACE FUNCTION public.tickets_dev_run(p_limit int DEFAULT 120)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_h jsonb; v_b jsonb; v_gt_evo int := 0; v_v int := 0; v_g int := 0; v_c int := 0; v_ask int := 0; v_cap int;
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
                            'enqueued', jsonb_build_object('vividseats', coalesce(v_v,0),
                                                           'gotickets_purchases', coalesce(v_g,0),
                                                           'gotickets_catalogue', coalesce(v_c,0)),
                            'catalogue_askable_remaining', v_ask);
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_run(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_run(int) TO service_role;

COMMENT ON FUNCTION public.tickets_dev_run(int) IS
  'tickets.dev bridge tick: harvest settled probes, enrich the hub from clusters, map GoTickets rows to TEvo from the hub (both-ways guarded, fill-only), then enqueue the next batch from three seeds -- Vivid orders, GoTickets purchases, and (mig 20260916220000) the GoTickets catalogue itself, nearest first, askable-before-limit. GET-only (RULE 2).';

-- ============================================================================================
-- APPLIED AND VERIFIED ON PROD, 2026-09-16 -- a 300-probe sample, then left live at 150/tick
-- ============================================================================================
-- FIRST TICK, before a single new probe returned:  gt_mapped_to_tevo = 243. That is step 3
-- catching up on every cluster harvested since 09-09 whose GoTickets row was never stamped,
-- because nothing scheduled it. 39 of the 243 are future events; the rest had already passed
-- while waiting for a function nobody called. The old seeds returned vividseats 0 and
-- gotickets_purchases 0 on that same tick -- the starvation diagnosis, confirmed by the tick.
--
-- THE GUARD FAILED ON ITS FIRST RUN, AND THE FAILURE IS RECORDED HERE, NOT SMOOTHED OVER:
-- double-claims went 235 -> 236. Two nights of 'Usher and Chris Brown' (gt 1563927 on 09-13,
-- 1566612 on 09-14) both stamped TEvo 3366101 at 16:37:52 -- the identical instant, because a
-- NOT EXISTS reads the statement-start snapshot and neither row existed yet. Half one of the
-- guard (the ok1 CTE) was added, the two rows were reverted by provenance marker (exactly two
-- rows matched; the marker is what makes that safe), and the backfill was re-run with both rows
-- NULL again: it returned 0 and both stayed NULL. Double-claims 235. The guard is proven the
-- only way a guard can be -- by being handed the exact case it exists for.
--
-- THE SAMPLE: 300 catalogue-seeded probes (150 by hand at 16:37, 150 by cron 652 at 16:38),
-- nearest events first, all settled within minutes:
--
--   found                                       189   (63%)
--   not_found                                   111   (37%)  -- 55% on the nearest batch, 19% on the next:
--                                                              events days away are the ones the
--                                                              marketplaces have already delisted
--   of found, cluster carries >=1 sibling id    163   (86%)
--   clusters gained                            +190   (5,614 -> 5,804)
--   marketplace ids gained                     +488   (19,391 -> 19,879)  ~2.6 per hit: GoTickets + ~1.6 siblings
--
-- "OTHER MARKETPLACES -> GOTICKETS" IS THE PART THAT WORKS, AND IT WORKS BY IDENTITY: one id per
-- marketplace per cluster, no pick, no score, nothing to tune. 488 ids for 300 free GET calls.
--
-- "GOTICKETS -> EVO" ON THIS SLICE: 0 through the hub, and the reason was measured rather than
-- guessed. All 163 sibling-bearing clusters have siblings the hub has NEVER SEEN -- no aq_event_map
-- row carries those Vivid/StubHub/TM ids at all -- so hub_backfill has nothing to resolve. Going
-- around the hub, straight to the TEvo mirror by venue-id + local day:
--
--   venue unresolvable by cross_source_venue_resolve   169   TEvo does not carry the venue
--   venue resolves, TEvo has nothing that day            11
--   EXACTLY ONE name-consistent TEvo event                5   mappable, by id + day + name guard
--   TEvo event that day, name guard fails                 4
--
-- 5 of 189 is 2.6%, and it should be read with its bias: nearest-first means this slice is the
-- residue every matcher has had weeks to fail on, at venues TEvo mostly does not carry. It is
-- the TEvo-ABSENT class that v_tickets_dev_no_tevo exists to name. A farther-out band will be
-- fresher and may map better; that is a second 150-probe sample, not an assumption.
--
-- WHAT THIS MEANS FOR THE OPERATOR'S PLAN: the fallback IS the payload. Where EVO exists the
-- existing matchers mostly already found it; where it does not, the cluster still hands the
-- GoTickets event its Vivid/StubHub/TM identity, which is what "map to gotix events if not evo"
-- asked for. The 5 that CAN reach EVO by venue-id + day are a small direct resolver (the
-- event_mapper_resolve_by_id shape, pointed at tickets_dev_event) -- a follow-up, not this file.
--
-- hub_backfill REPORTS hub_rows_enriched = 31 ON EVERY CALL. It is not writing 31 rows each time:
-- its WHERE matches rows where the CASE then yields NULL, so the row is touched and unchanged.
-- Cosmetic, misleading, not this migration's, noted so nobody reads it as progress.
--
-- LEFT LIVE: cron 652 now drains the catalogue at 150 per 15-minute tick, ~14,400/day, ~8 days
-- to the 104,350 askable. Every call is the free GET endpoint; askable() prevents re-asking;
-- the tick's own return value carries catalogue_askable_remaining so a future starvation is
-- visible without a query.
