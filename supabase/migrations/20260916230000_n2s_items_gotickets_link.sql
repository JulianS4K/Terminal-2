-- Migration 20260916230000 · level:data-collection · lane:D7 (operator-routed from the A1 session, 2026-09-16) · writes:n2s_items (gt_event_id, gt_mapped_via, gt_mapped_at), n2s_link_gotickets() fn · reads:gotickets_sales, s4kcs_orders, gotickets_event, aq_event_map · pre:20260916220000
--
-- ============================================================================================
-- N2S HAD EVO ON 198 OF 201 OPEN FUTURE OBLIGATIONS, AND GOTICKETS ON 109 -- FOR NO GOOD REASON
-- ============================================================================================
-- n2s_items carries tevo_event_id and no GoTickets column at all. The only way an obligation
-- could be said to have a GoTickets id was by joining back to the CRM row by order number, and
-- that join reaches 708 of 1,572 obligations (45%). So 87 of the 89 EVO-only open future rows
-- were not a mapping failure: their TEvo event resolves to EXACTLY ONE GoTickets event through
-- gotickets_event or aq_event_map, and the id had nowhere to land.
--
-- Operator 2026-09-16: "Add the column then."
--
-- LANE NOTE. n2s_* is D7's surface (PROJECT_BIBLE §2.3, a named subset of D0). This session runs
-- as A1; the write is operator-routed per CLAUDE.md §3 ("Operator may explicitly route work to a
-- session outside its default lane"). Recorded here so it does not read as a silent cross-lane
-- write.
--
-- FOUR ROUTES, STRONGEST FIRST, EVERY ONE FILL-ONLY. Same discipline as 20260916160000 on the CRM,
-- for the same reason: a wrong GoTickets id on an obligation points the cover search at the
-- wrong event, and that is a purchase decision, not a report.
--   1. sale_identity      gotickets_sales.gt_sale_id = order_number         exact, nothing to tune
--   2. crm_order          s4kcs_orders.gt_event_id by order_number          inherits the CRM's own
--                                                                            provenance-guarded link
--   3. tevo_spine_unique  gotickets_event.tevo_event_id = tevo_event_id      only where ONE row claims it
--   4. aq_tevo            aq_event_map.gotickets_event_id via tevo           only where ONE distinct id
-- Route 2 sits above 3 and 4 because the CRM link already went through identity-first filling and
-- the both-ways refusals; re-deriving it from the spine here could only disagree with it, never
-- improve on it.
--
-- AMBIGUITY IS LEFT NULL AND COUNTED. A TEvo event with two GoTickets claimants (the 235
-- double-claims) or two distinct hub ids gets nothing from routes 3-4. "Unknown" is true; a guess
-- would be "known" and false, on a surface that buys tickets.
--
-- FUTURE BY DEFAULT (event_dt >= now()), matching the CRM migrations. An obligation whose event
-- has passed is not going to be covered. p_horizon_days widens it for a later backfill. Note that
-- is_terminal is NEVER TRUE on any of the 1,572 rows today -- either nothing has ever resolved or
-- the flag is not being set. That is D7's to look at; this migration does not filter on it, so it
-- cannot be silently wrong if the flag starts working.
--
-- WHAT THIS CANNOT REACH, measured before writing: 2 obligations GoTickets never listed, 2 for an
-- event TEvo does not carry (a neutral-site NBA preseason game in Ames, Iowa -- venue resolves,
-- no event within a day of it), and 1 parking pass, which every mapper in the chain excludes by
-- design and which arguably should not be an open obligation at all.
-- ============================================================================================

ALTER TABLE public.n2s_items
  ADD COLUMN IF NOT EXISTS gt_event_id   bigint,
  ADD COLUMN IF NOT EXISTS gt_mapped_via text,
  ADD COLUMN IF NOT EXISTS gt_mapped_at  timestamptz;

CREATE INDEX IF NOT EXISTS n2s_items_gt_event_id_idx
  ON public.n2s_items (gt_event_id) WHERE gt_event_id IS NOT NULL;

COMMENT ON COLUMN public.n2s_items.gt_event_id IS
  'GoTickets event this obligation''s sold ticket belongs to. Filled by n2s_link_gotickets(), fill-only, strongest route first: sale identity, then the CRM row''s own link, then the TEvo spine where exactly one GoTickets row claims it, then the hub where exactly one distinct id. NULL under ambiguity means unknown, not none (mig 20260916230000).';

COMMENT ON COLUMN public.n2s_items.gt_mapped_via IS
  'sale_identity = gotickets_sales.gt_sale_id matched order_number (exact). crm_order = inherited from s4kcs_orders.gt_event_id by order_number. tevo_spine_unique = derived through tevo_event_id, single claimant. aq_tevo = derived through aq_event_map, single distinct id. Read this before trusting the id: they are not equally strong.';

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

  DROP TABLE IF EXISTS _n2sc;
  CREATE TEMP TABLE _n2sc ON COMMIT DROP AS
  SELECT n.n2s_id, n.gt_event_id AS gt_now,
         gs.gt_event_id AS gt_identity,
         o.gt_event_id  AS gt_crm,
         -- exactly-one-claimant, or nothing. min() is required: HAVING count(*) = 1 makes this an
         -- aggregate query, so the selected column must be aggregated; with one row min() IS that row.
         (SELECT min(g.gt_event_id) FROM public.gotickets_event g
           WHERE g.tevo_event_id = n.tevo_event_id HAVING count(*) = 1) AS gt_spine,
         (SELECT min(a.gotickets_event_id) FROM public.aq_event_map a
           WHERE a.tevo_event_id = n.tevo_event_id AND a.gotickets_event_id IS NOT NULL
          HAVING count(DISTINCT a.gotickets_event_id) = 1) AS gt_aq,
         (SELECT count(*) FROM public.gotickets_event g WHERE g.tevo_event_id = n.tevo_event_id) AS claimants,
         (SELECT count(DISTINCT a.gotickets_event_id) FROM public.aq_event_map a
           WHERE a.tevo_event_id = n.tevo_event_id AND a.gotickets_event_id IS NOT NULL) AS aq_ids
    FROM public.n2s_items n
    LEFT JOIN public.gotickets_sales gs ON gs.gt_sale_id::text = n.order_number
    LEFT JOIN public.s4kcs_orders   o  ON o.s4k_order_id = n.order_number AND o.gt_event_id IS NOT NULL
   WHERE n.event_dt >= v_from
     AND coalesce(n.event_name, '') !~* 'parking|shuttle';

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
  'Fills n2s_items.gt_event_id, fill-only, strongest route first: sale identity, the CRM row''s own link, the TEvo spine where exactly one GoTickets row claims it, the hub where exactly one distinct id. Ambiguity is left NULL and counted -- a wrong id here points the cover search at the wrong event. DRY RUN unless p_apply => true. Future-only by default; p_horizon_days widens it (mig 20260916230000).';

-- ============================================================================================
-- APPLIED AND VERIFIED ON PROD, 2026-09-16 (open future obligations)
-- ============================================================================================
--   eligible (future, non-parking)               199
--   filled by SALE IDENTITY                       13
--   filled by CRM ORDER                           96
--   filled by TEVO SPINE (single claimant)        65
--   filled by AQ (single distinct id)             21
--   still unfilled                                 4
--     refused as ambiguous                         0
--
-- THE DRY RUN AND THE APPLY RETURNED THE SAME FIVE NUMBERS, and both matched the count made
-- BEFORE the column existed (87 reachable + 109 already reachable through the CRM join, minus
-- the parking rows the filter drops). Nothing was discovered by writing; it was all known first.
--
--   open future N2S obligations, before -> after:
--     both EVO and GoTickets     109 -> 195   of 201
--     EVO only                    89 ->   3   Tame Impala Parking (filter), Empire of the Sun, Jack Johnson
--     neither                      3 ->   3   2x NBA Preseason at Hilton Coliseum (TEvo-absent), J. Cole parking
--
-- THE SIX THAT REMAIN ARE NOT MAPPER WORK: two GoTickets never listed, two for an event TEvo does
-- not carry, two parking passes that every mapper in the chain excludes by design. Whether parking
-- passes belong in the obligation book at all is D7's question, not this migration's.
--
-- 33 "DANGLING" IDS, CHECKED RATHER THAN ASSUMED. 33 rows now hold a gt_event_id that is not in
-- gotickets_event. Every one of the 33 is present in aq_event_map, 27 are present in
-- gotickets_sales -- GoTickets' own record of the sale -- and 30 in the CRM. They are real ids.
-- The gotickets_event MIRROR does not carry them (its coverage, not their validity), which is a
-- catalogue gap on A1's side and is not a reason to withhold an id three other tables corroborate.
--
-- 41 SECONDS TO APPLY 199 ROWS, against 6.8 for the dry run. The four correlated subqueries per
-- row against aq_event_map are cheap to read and dear to run four times each inside an UPDATE.
-- Irrelevant at this size, worth a temp-table rewrite before p_horizon_days is pointed at the
-- 1,371 past obligations.
--
-- is_terminal IS NEVER TRUE. 1,572 rows, 0 terminal. Either nothing has ever resolved or the flag
-- is not being written. Not filtered on here, deliberately, so this cannot go wrong when it is
-- fixed -- but it is the kind of silent thing D7 should look at.
