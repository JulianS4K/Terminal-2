-- Migration 20260916160000 · level:data-collection · lane:A1 · writes:s4kcs_orders (gt_event_id, gt_mapped_via, gt_mapped_at), s4kcs_link_gotickets() fn · reads:gotickets_sales, gotickets_event · pre:20260916140000
--
-- ============================================================================================
-- THE CRM HAD NOWHERE TO PUT A GOTICKETS ID
-- ============================================================================================
-- s4kcs_orders carries tevo_event_id, aq_short_event_id, venue_short_id, performer_short_id --
-- and no GoTickets column at all. So "is this CRM order mapped to GoTickets?" could only ever be
-- answered by chaining through TEvo, which silently makes the answer WRONG wherever more than one
-- GoTickets row claims the same TEvo event.
--
-- Operator 2026-09-16: "Map only the future orders to both for now, start with unmapped to both
-- and proceed ... map to go tickets at least."
--
-- TWO ROUTES, AND THEY ARE NOT EQUAL. Measured on prod over 27,701 future non-parking orders:
--
--   route                                            orders
--   identity  gotickets_sales.gt_sale_id = s4k_order_id   2,112
--   via TEvo  gotickets_event.tevo_event_id = o.tevo…    18,322
--   either                                              19,084
--   neither                                              8,617
--
-- IDENTITY WINS WHERE THEY DISAGREE, and the disagreements say why. 52 future orders resolve to
-- different GoTickets events depending on the route:
--     34  the TEvo event has MORE THAN ONE GoTickets claimant -- the 235 double-claims, showing
--         up downstream. "The" GoTickets event for that TEvo id does not exist; identity picks
--         the actual one.
--     17  the identity row's GoTickets event is itself unmapped to TEvo, so the TEvo route
--         could never have found it
--      2  a genuine conflict worth an operator's eye
--
-- gotickets_sales.gt_sale_id IS s4kcs_orders.s4k_order_id for GoTickets-sourced rows -- the same
-- order seen from the seller side. That is an identity, not a similarity: no name, no date, no
-- venue, nothing to tune and nothing to get wrong. It is therefore pass 1, and pass 2 never
-- overwrites it.
--
-- PASS 2 REFUSES AMBIGUITY RATHER THAN GUESSING. It fills from the TEvo spine only where EXACTLY
-- ONE GoTickets row claims that TEvo event. Where several do, the honest answer is "unknown" and
-- the column stays NULL: propagating a double claim into the CRM would turn a mapping defect into
-- a revenue-reporting defect, and it would be invisible. Those rows resolve for free once the
-- double claims are resolved -- which is an operator call, not this migration's.
--
-- FUTURE ONLY, deliberately, per the operator. p_horizon_days exists so a later backfill can widen
-- it; the default leaves the ~15,000 past orders alone. Note the past backlog is proportionally
-- WORSE (892 of 15,393 with no TEvo id, 5.8%, against 0.9% forward) partly because the mapper
-- surfaces filter on event_date >= current_date - 7, so a past order that was never mapped can
-- never be retried. That is a real problem and it is not this migration's to solve.
-- ============================================================================================

ALTER TABLE public.s4kcs_orders
  ADD COLUMN IF NOT EXISTS gt_event_id   bigint,
  ADD COLUMN IF NOT EXISTS gt_mapped_via text,
  ADD COLUMN IF NOT EXISTS gt_mapped_at  timestamptz;

CREATE INDEX IF NOT EXISTS s4kcs_orders_gt_event_id_idx
  ON public.s4kcs_orders (gt_event_id) WHERE gt_event_id IS NOT NULL;

COMMENT ON COLUMN public.s4kcs_orders.gt_event_id IS
  'GoTickets event this CRM order belongs to. Filled by s4kcs_link_gotickets(): pass 1 by IDENTITY (gotickets_sales.gt_sale_id = s4k_order_id, exact, authoritative), pass 2 from the TEvo spine but ONLY where exactly one GoTickets row claims that TEvo event. NULL where the TEvo event has several claimants -- that is "unknown", not "none", and it clears when the double claims are resolved (mig 20260916160000).';

COMMENT ON COLUMN public.s4kcs_orders.gt_mapped_via IS
  'sale_identity = gotickets_sales.gt_sale_id matched s4k_order_id (exact). tevo_spine_unique = derived through tevo_event_id where exactly one GoTickets row claims it. Read this before trusting the id: the two are not equally strong.';

CREATE OR REPLACE FUNCTION public.s4kcs_link_gotickets(
  p_apply        boolean DEFAULT false,
  p_horizon_days int     DEFAULT NULL   -- NULL = future only; a number widens back that many days
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_from        date;
  v_identity    int := 0;
  v_spine       int := 0;
  v_ambiguous   int := 0;
  v_remaining   int := 0;
  v_eligible    int := 0;
  v_started     timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);

  v_from := CASE WHEN p_horizon_days IS NULL THEN current_date
                 ELSE current_date - p_horizon_days END;

  DROP TABLE IF EXISTS _cand;
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
  SELECT o.source, o.s4k_order_id, o.tevo_event_id, o.gt_event_id AS gt_now,
         gs.gt_event_id AS gt_identity,
         -- exactly-one-claimant, or nothing. count(*) = 1 is the whole guard.
         -- min() is required, not cosmetic: HAVING count(*) = 1 makes this an aggregate query,
         -- so the selected column must be aggregated too. With exactly one row, min() IS that row.
         (SELECT min(g.gt_event_id) FROM public.gotickets_event g
           WHERE g.tevo_event_id = o.tevo_event_id
          HAVING count(*) = 1) AS gt_spine,
         (SELECT count(*) FROM public.gotickets_event g
           WHERE g.tevo_event_id = o.tevo_event_id) AS claimants
    FROM public.s4kcs_orders o
    LEFT JOIN public.gotickets_sales gs
           ON gs.gt_sale_id::text = o.s4k_order_id
   WHERE o.event_date >= v_from
     AND coalesce(o.event_name, '') !~* 'parking|shuttle';

  SELECT count(*) INTO v_eligible FROM _cand;
  SELECT count(*) INTO v_ambiguous FROM _cand WHERE gt_now IS NULL AND gt_identity IS NULL AND claimants > 1;

  IF NOT p_apply THEN
    SELECT count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NOT NULL),
           count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NULL AND gt_spine IS NOT NULL),
           count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NULL AND gt_spine IS NULL)
      INTO v_identity, v_spine, v_remaining
      FROM _cand;
    RETURN jsonb_build_object(
      'applied', false, 'note', 'DRY RUN -- nothing written.',
      'horizon_from', v_from::text, 'eligible_orders', v_eligible,
      'would_fill_by_identity', v_identity, 'would_fill_by_tevo_spine', v_spine,
      'left_unfilled', v_remaining,
      'of_those_blocked_as_ambiguous', v_ambiguous,
      'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
  END IF;

  -- PASS 1 -- identity. Fill-only.
  UPDATE public.s4kcs_orders o
     SET gt_event_id = c.gt_identity, gt_mapped_via = 'sale_identity', gt_mapped_at = now()
    FROM _cand c
   WHERE o.s4k_order_id = c.s4k_order_id AND o.source = c.source
     AND o.gt_event_id IS NULL AND c.gt_identity IS NOT NULL;
  GET DIAGNOSTICS v_identity = ROW_COUNT;

  -- PASS 2 -- TEvo spine, unique claimant only. Never overwrites pass 1.
  UPDATE public.s4kcs_orders o
     SET gt_event_id = c.gt_spine, gt_mapped_via = 'tevo_spine_unique', gt_mapped_at = now()
    FROM _cand c
   WHERE o.s4k_order_id = c.s4k_order_id AND o.source = c.source
     AND o.gt_event_id IS NULL AND c.gt_identity IS NULL AND c.gt_spine IS NOT NULL;
  GET DIAGNOSTICS v_spine = ROW_COUNT;

  SELECT count(*) INTO v_remaining
    FROM public.s4kcs_orders
   WHERE event_date >= v_from AND coalesce(event_name,'') !~* 'parking|shuttle'
     AND gt_event_id IS NULL;

  RETURN jsonb_build_object(
    'applied', true, 'horizon_from', v_from::text, 'eligible_orders', v_eligible,
    'filled_by_identity', v_identity, 'filled_by_tevo_spine', v_spine,
    'still_unfilled', v_remaining,
    'of_those_blocked_as_ambiguous', v_ambiguous,
    'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.s4kcs_link_gotickets(boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.s4kcs_link_gotickets(boolean, int) TO service_role;

COMMENT ON FUNCTION public.s4kcs_link_gotickets(boolean, int) IS
  'Fills s4kcs_orders.gt_event_id. Pass 1 by identity (gotickets_sales.gt_sale_id = s4k_order_id), pass 2 from the TEvo spine ONLY where exactly one GoTickets row claims that TEvo event -- ambiguity is left NULL rather than guessed, because a wrong CRM link is a revenue-reporting defect and an invisible one. Fill-only in both passes. DRY RUN unless p_apply => true. Future-only by default; p_horizon_days widens it (mig 20260916160000).';

-- ============================================================================================
-- APPLIED AND VERIFIED ON PROD, 2026-09-16 (future orders only, per the operator)
-- ============================================================================================
--   eligible future non-parking orders          27,701
--   filled by IDENTITY                           2,112   gotickets_sales.gt_sale_id = s4k_order_id
--   filled by TEVO SPINE (unique claimant)      16,607
--   still unfilled                               8,982
--     of those, REFUSED as ambiguous               376   the TEvo event has >1 GoTickets claimant
--
--   CRM future orders, before -> after:
--     mapped to BOTH            18,322 -> 18,683   (+361)
--     EVO only                   9,121 ->  8,775   (-346)
--     GoTickets only (new)            0 ->     36   previously unmapped to BOTH; rescued by identity
--     still unmapped to BOTH        243 ->    207
--
-- THE 36 ARE THE POINT OF THE IDENTITY PASS. They are GoTickets-sourced CRM orders that no
-- TEvo-based route could ever have reached, because the GoTickets event they belong to is itself
-- unmapped to TEvo. Chaining through TEvo cannot find what TEvo does not have; the sale id can.
--
-- DEFECT FOUND ON FIRST RUN: HAVING count(*) = 1 without an aggregate on the selected column is a
-- syntax error, not a no-op -- "column g.gt_event_id must appear in the GROUP BY clause". The
-- dry-run default caught it before anything was written, which is the entire reason the default
-- is a dry run.
--
-- WHAT IS LEFT, and none of it is this migration's to fix:
--   * 8,606 orders whose event GoTickets does not appear to carry at all. Whether GoTickets lists
--     them and we missed, or never listed them, is UNMEASURED -- and it is the only split that
--     turns this number into a backlog rather than a fact.
--   * 376 blocked by double claims. They resolve for free the moment an operator decides which
--     claimant wins; nothing here should guess.
--   * 207 still unmapped to both. By source: SeatGeek 90 and TickPick 6 CANNOT be reached by the
--     tickets.dev bridge at all -- it answers 501 source_not_indexed for both, explicitly
--     non-retryable (mig 20260914211000). That is 96 of the 207 closed off by the vendor, not by us.
--   * the ~15,000 PAST orders, deliberately untouched. Their backlog is proportionally worse
--     (5.8% with no TEvo id against 0.9% forward), partly because the mapper surfaces filter on
--     event_date >= current_date - 7, so a past order never mapped can never be retried.
