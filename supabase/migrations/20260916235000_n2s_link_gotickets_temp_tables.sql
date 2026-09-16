-- Migration 20260916235000 · level:data-collection · lane:D7 (operator-routed from the A1 session) · writes:n2s_link_gotickets() fn (rewrite, same contract) · reads:gotickets_sales, s4kcs_orders, gotickets_event, aq_event_map · pre:20260916230000
--
-- ============================================================================================
-- 41 SECONDS FOR 199 ROWS BECAME 60+ FOR 191, AND A FUNCTION THAT SLOW CANNOT GO ON A CRON
-- ============================================================================================
-- 20260916230000 flagged it at apply time: four correlated subqueries per obligation, each
-- re-scanning gotickets_event or aq_event_map inside the UPDATE, "irrelevant at this size, worth
-- a temp-table rewrite before p_horizon_days is pointed at the past". Three hours later the
-- future-only run alone crossed the 60s MCP ceiling. It committed -- statement_timeout inside
-- is 120s -- but a linker that is about to run every fifteen minutes next to three others cannot
-- cost a minute a tick.
--
-- SAME CONTRACT, SAME ROUTES, SAME ORDER, SAME FILL-ONLY DISCIPLINE. What changes is only that
-- the TEvo -> GoTickets lookups are built ONCE as keyed temp tables (the shape
-- s4kcs_link_marketplaces already uses, at 2.5s for 28,121 orders) and joined, instead of being
-- evaluated per row. The return object is byte-for-byte the same keys, so nothing reading it
-- notices. count(DISTINCT) = 1 / min() is the same single-claimant idiom as everywhere else today.
-- ============================================================================================

CREATE OR REPLACE FUNCTION public.n2s_link_gotickets(
  p_apply        boolean DEFAULT false,
  p_horizon_days int     DEFAULT NULL   -- NULL = future only; a number widens back that many days
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_from      timestamptz;
  v_eligible  int := 0;
  v_identity  int := 0;
  v_crm       int := 0;
  v_spine     int := 0;
  v_aq        int := 0;
  v_ambiguous int := 0;
  v_remaining int := 0;
  v_started   timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  v_from := CASE WHEN p_horizon_days IS NULL THEN now()
                 ELSE now() - make_interval(days => p_horizon_days) END;

  -- TEvo -> GoTickets through the catalogue mirror, ONE row per TEvo event, built once.
  DROP TABLE IF EXISTS _n2s_spine;
  CREATE TEMP TABLE _n2s_spine ON COMMIT DROP AS
  SELECT tevo_event_id,
         CASE WHEN count(*) = 1 THEN min(gt_event_id) END AS gt,
         count(*) AS claimants
    FROM public.gotickets_event WHERE tevo_event_id IS NOT NULL GROUP BY 1;
  CREATE INDEX ON _n2s_spine (tevo_event_id);

  -- TEvo -> GoTickets through the hub, ONE row per TEvo event, built once.
  DROP TABLE IF EXISTS _n2s_aq;
  CREATE TEMP TABLE _n2s_aq ON COMMIT DROP AS
  SELECT tevo_event_id,
         CASE WHEN count(DISTINCT gotickets_event_id) = 1 THEN min(gotickets_event_id) END AS gt,
         count(DISTINCT gotickets_event_id) AS ids
    FROM public.aq_event_map WHERE tevo_event_id IS NOT NULL AND gotickets_event_id IS NOT NULL GROUP BY 1;
  CREATE INDEX ON _n2s_aq (tevo_event_id);

  DROP TABLE IF EXISTS _n2sc;
  CREATE TEMP TABLE _n2sc ON COMMIT DROP AS
  SELECT n.n2s_id, n.gt_event_id AS gt_now,
         gs.gt_event_id AS gt_identity,
         o.gt_event_id  AS gt_crm,
         sp.gt          AS gt_spine,
         aq.gt          AS gt_aq,
         coalesce(sp.claimants, 0) AS claimants,
         coalesce(aq.ids, 0)       AS aq_ids
    FROM public.n2s_items n
    LEFT JOIN public.gotickets_sales gs ON gs.gt_sale_id::text = n.order_number
    LEFT JOIN public.s4kcs_orders   o  ON o.s4k_order_id = n.order_number AND o.gt_event_id IS NOT NULL
    LEFT JOIN _n2s_spine sp ON sp.tevo_event_id = n.tevo_event_id
    LEFT JOIN _n2s_aq    aq ON aq.tevo_event_id = n.tevo_event_id
   WHERE n.event_dt >= v_from
     AND coalesce(n.event_name, '') !~* 'parking|shuttle';
  CREATE INDEX ON _n2sc (n2s_id);

  SELECT count(*),
         count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NULL AND gt_crm IS NULL
                            AND gt_spine IS NULL AND gt_aq IS NULL AND (claimants > 1 OR aq_ids > 1))
    INTO v_eligible, v_ambiguous FROM _n2sc;

  IF NOT p_apply THEN
    SELECT count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NOT NULL),
           count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NULL AND gt_crm IS NOT NULL),
           count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NULL AND gt_crm IS NULL AND gt_spine IS NOT NULL),
           count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NULL AND gt_crm IS NULL AND gt_spine IS NULL AND gt_aq IS NOT NULL),
           count(*) FILTER (WHERE gt_now IS NULL AND gt_identity IS NULL AND gt_crm IS NULL AND gt_spine IS NULL AND gt_aq IS NULL)
      INTO v_identity, v_crm, v_spine, v_aq, v_remaining FROM _n2sc;
    RETURN jsonb_build_object(
      'applied', false, 'note', 'DRY RUN -- nothing written.',
      'horizon_from', v_from::text, 'eligible_obligations', v_eligible,
      'would_fill', jsonb_build_object('sale_identity', v_identity, 'crm_order', v_crm,
                                       'tevo_spine_unique', v_spine, 'aq_tevo', v_aq),
      'left_unfilled', v_remaining, 'of_those_blocked_as_ambiguous', v_ambiguous,
      'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
  END IF;

  UPDATE public.n2s_items n SET gt_event_id = c.gt_identity, gt_mapped_via = 'sale_identity', gt_mapped_at = now()
    FROM _n2sc c WHERE n.n2s_id = c.n2s_id AND n.gt_event_id IS NULL AND c.gt_identity IS NOT NULL;
  GET DIAGNOSTICS v_identity = ROW_COUNT;

  UPDATE public.n2s_items n SET gt_event_id = c.gt_crm, gt_mapped_via = 'crm_order', gt_mapped_at = now()
    FROM _n2sc c WHERE n.n2s_id = c.n2s_id AND n.gt_event_id IS NULL AND c.gt_crm IS NOT NULL;
  GET DIAGNOSTICS v_crm = ROW_COUNT;

  UPDATE public.n2s_items n SET gt_event_id = c.gt_spine, gt_mapped_via = 'tevo_spine_unique', gt_mapped_at = now()
    FROM _n2sc c WHERE n.n2s_id = c.n2s_id AND n.gt_event_id IS NULL AND c.gt_spine IS NOT NULL;
  GET DIAGNOSTICS v_spine = ROW_COUNT;

  UPDATE public.n2s_items n SET gt_event_id = c.gt_aq, gt_mapped_via = 'aq_tevo', gt_mapped_at = now()
    FROM _n2sc c WHERE n.n2s_id = c.n2s_id AND n.gt_event_id IS NULL AND c.gt_aq IS NOT NULL;
  GET DIAGNOSTICS v_aq = ROW_COUNT;

  SELECT count(*) INTO v_remaining FROM public.n2s_items
   WHERE event_dt >= v_from AND coalesce(event_name,'') !~* 'parking|shuttle' AND gt_event_id IS NULL;

  RETURN jsonb_build_object(
    'applied', true, 'horizon_from', v_from::text, 'eligible_obligations', v_eligible,
    'filled', jsonb_build_object('sale_identity', v_identity, 'crm_order', v_crm,
                                 'tevo_spine_unique', v_spine, 'aq_tevo', v_aq),
    'still_unfilled', v_remaining, 'of_those_blocked_as_ambiguous', v_ambiguous,
    'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.n2s_link_gotickets(boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_link_gotickets(boolean, int) TO service_role;

COMMENT ON FUNCTION public.n2s_link_gotickets(boolean, int) IS
  'Fills n2s_items.gt_event_id, fill-only, strongest route first: sale identity, the CRM row''s own link, the TEvo spine where exactly one GoTickets row claims it, the hub where exactly one distinct id. Ambiguity is left NULL and counted -- a wrong id here points the cover search at the wrong event. DRY RUN unless p_apply => true. Future-only by default; p_horizon_days widens it (mig 20260916230000; keyed temp tables instead of per-row subqueries, mig 20260916235000).';

-- ============================================================================================
-- APPLIED AND VERIFIED ON PROD, 2026-09-16
-- ============================================================================================
--   old function, future scope, 191 rows      60,000+ ms   (crossed the MCP ceiling; committed anyway)
--   new function, same scope, same rows           177 ms
--   same answer: would_fill 0 across all four routes, 4 left, 0 ambiguous -- the rows the slow
--   run had just filled are exactly the rows the fast run finds nothing to do on. Idempotent
--   and equivalent in one dry run.
--
-- WHY THIS MIGRATION EXISTS AT ALL: the linkers built today -- s4kcs_link_gotickets,
-- s4kcs_link_marketplaces, s4kcs_link_tickets_dev, n2s_link_gotickets -- were all run by hand and
-- none is scheduled. Measured at 22:00Z: future CRM EVO-only had climbed 650 -> 1,012 since the
-- last hand run, 333 of them orders that ARRIVED after it, 204 of those GoTickets-reachable that
-- minute. The columns decay with every CRM pull unless the linkers run on a tick, and a linker
-- that costs a minute cannot. Re-running all four by hand at 22:05Z: GoTickets on future CRM
-- orders 26,883 -> 27,303 of 28,131 (+40 identity, +240 spine, +140 hub), tdev_id +1,475 from
-- the drain's new clusters, N2S 182 -> 187 of 191. Scheduling them is the operator's call
-- (cron changes are gated) and is the open ask.
