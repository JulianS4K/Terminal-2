-- Migration 20260916180000 · level:data-collection · lane:A1 · writes:s4kcs_orders (tdev_id, tdev_mapped_via, tdev_mapped_at), s4kcs_link_tickets_dev() fn · reads:tickets_dev_source_id, aq_event_map · pre:20260916160000
--
-- ============================================================================================
-- THE CRM NOW HAS A GOTICKETS ID. IT STILL HAS NO CROSS-MARKETPLACE ONE.
-- ============================================================================================
-- 20260916160000 gave s4kcs_orders a gt_event_id, which answers "which GoTickets event is this".
-- It does not answer "which EVENT is this" -- the thing StubHub, Vivid, Ticketmaster and GoTickets
-- all sell separately under four different ids. tickets.dev's /v1/events catalogue already holds
-- exactly that: one ULID (tdev_id) per real-world event, with tickets_dev_source_id mapping each
-- marketplace's own id into it (mig 20260914211000). Nothing in the CRM pointed at it.
--
-- Operator 2026-09-16: "Add to tickets column to crm where necessary."
--
-- "WHERE NECESSARY" IS A MEASUREMENT, NOT A FIGURE OF SPEECH. A column that nothing can fill is
-- worse than no column, because it reads as "we checked and there is none". Measured on prod
-- across 27,713 future non-parking CRM orders BEFORE writing a line of this:
--
--   route                                                        orders
--   R1  via gt_event_id -> tickets_dev_source_id(gotickets)      15,443
--   R2  via tevo_event_id -> aq_event_map -> any marketplace      4,790
--   neither                                                       7,480
--                                                                -------
--   reachable                                                    20,233   (73%)
--
-- 73% is the answer to "necessary". The catalogue itself is small -- 5,613 events, 5,498 of them
-- future -- but it is dense exactly where our orders are.
--
-- R1 IS AN IDENTITY AND IS THEREFORE PASS 1. tickets_dev_source_id is keyed
-- PRIMARY KEY (marketplace, source_event_id), so a GoTickets id resolves to at most one cluster
-- BY CONSTRUCTION. There is no scoring, no window, nothing to tune and nothing to get wrong.
--
-- R2 IS AN INFERENCE AND IS THEREFORE PASS 2, AND IT REFUSES AMBIGUITY. Hopping TEvo -> aq_event_map
-- -> a marketplace id -> a cluster can land on more than one cluster when the marketplaces
-- disagree about what is one event. Measured: 4,830 TEvo events reach exactly one cluster, 16
-- reach two, 1 reaches three. Pass 2 fills only the 4,830 and leaves the 17 NULL. NULL here means
-- "unknown", which is true; a guess would mean "known", which would not be, and it would be
-- invisible downstream.
--
-- WHERE THE TWO ROUTES OVERLAP, MEASURED, NOT ASSUMED: they agree on 15,247 future orders and
-- DISAGREE ON 7. Pass 2 is fill-only, so the 7 keep the identity answer without needing a special
-- case -- but they are counted and returned (route_disagreements) rather than swallowed, because
-- 7 orders where a direct id and a three-hop inference reach different real-world events is a
-- signal about aq_event_map, not noise to be tidied away.
--
-- NO FOREIGN KEY TO tickets_dev_event, DELIBERATELY. tickets_dev_event is a CACHE of an upstream
-- catalogue and tickets_dev_source_id already cascades from it. An FK from the CRM would let a
-- routine cache prune either fail or, far worse, cascade into orders. A dangling tdev_id after a
-- prune is a stale pointer; a deleted order is a business record destroyed by a cache eviction.
-- Those are not comparable, so this column is an unenforced reference on purpose.
--
-- FUTURE ONLY by default, matching 20260916160000 and the operator's earlier "future orders only".
-- p_horizon_days widens it. RULE 2 is untouched: this migration reads two tables we already hold
-- and issues no upstream call of any kind.
-- ============================================================================================

ALTER TABLE public.s4kcs_orders
  ADD COLUMN IF NOT EXISTS tdev_id         text,
  ADD COLUMN IF NOT EXISTS tdev_mapped_via text,
  ADD COLUMN IF NOT EXISTS tdev_mapped_at  timestamptz;

CREATE INDEX IF NOT EXISTS s4kcs_orders_tdev_id_idx
  ON public.s4kcs_orders (tdev_id) WHERE tdev_id IS NOT NULL;

COMMENT ON COLUMN public.s4kcs_orders.tdev_id IS
  'tickets.dev cluster (tickets_dev_event.tdev_id) this CRM order''s event belongs to -- the cross-marketplace identity, not any one marketplace''s id. Filled by s4kcs_link_tickets_dev(). NOT a foreign key on purpose: tickets_dev_event is a prunable cache, and an FK would let a cache eviction cascade into business records (mig 20260916180000).';

COMMENT ON COLUMN public.s4kcs_orders.tdev_mapped_via IS
  'gotickets_identity = resolved from gt_event_id through tickets_dev_source_id, whose PK makes it exact. tevo_spine_unique = inferred through aq_event_map and only where the hop lands on exactly one cluster. The first is an identity, the second is an inference; read this before trusting the id.';

CREATE OR REPLACE FUNCTION public.s4kcs_link_tickets_dev(
  p_apply        boolean DEFAULT false,
  p_horizon_days int     DEFAULT NULL   -- NULL = future only; a number widens back that many days
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_from       date;
  v_gt         int := 0;
  v_spine      int := 0;
  v_ambiguous  int := 0;
  v_disagree   int := 0;
  v_remaining  int := 0;
  v_eligible   int := 0;
  v_started    timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);

  v_from := CASE WHEN p_horizon_days IS NULL THEN current_date
                 ELSE current_date - p_horizon_days END;

  -- The TEvo -> cluster hop, built ONCE (~4,850 rows) rather than re-derived per order. clusters
  -- is the guard; tdev_id is only ever read when clusters = 1, and with one distinct value min()
  -- IS that value.
  DROP TABLE IF EXISTS _tdspine;
  CREATE TEMP TABLE _tdspine ON COMMIT DROP AS
  SELECT a.tevo_event_id,
         min(s.tdev_id)             AS tdev_id,
         count(DISTINCT s.tdev_id)  AS clusters
    FROM public.aq_event_map a
    JOIN public.tickets_dev_source_id s
      ON (s.marketplace = 'vividseats'   AND s.source_event_id = a.vivid_event_id::text)
      OR (s.marketplace = 'stubhub'      AND s.source_event_id = a.sh_event_id::text)
      OR (s.marketplace = 'ticketmaster' AND s.source_event_id = a.tm_event_id::text)
      OR (s.marketplace = 'gotickets'    AND s.source_event_id = a.gotickets_event_id::text)
   WHERE a.tevo_event_id IS NOT NULL
   GROUP BY 1;
  CREATE INDEX ON _tdspine (tevo_event_id);

  DROP TABLE IF EXISTS _tdc;
  CREATE TEMP TABLE _tdc ON COMMIT DROP AS
  SELECT o.source, o.s4k_order_id, o.tdev_id AS td_now,
         sg.tdev_id AS td_gt,
         CASE WHEN sp.clusters = 1 THEN sp.tdev_id END AS td_spine,
         coalesce(sp.clusters, 0) AS clusters
    FROM public.s4kcs_orders o
    LEFT JOIN public.tickets_dev_source_id sg
           ON sg.marketplace = 'gotickets' AND sg.source_event_id = o.gt_event_id::text
    LEFT JOIN _tdspine sp ON sp.tevo_event_id = o.tevo_event_id
   WHERE o.event_date >= v_from
     AND coalesce(o.event_name, '') !~* 'parking|shuttle';

  SELECT count(*),
         count(*) FILTER (WHERE td_now IS NULL AND td_gt IS NULL AND clusters > 1),
         count(*) FILTER (WHERE td_gt IS NOT NULL AND td_spine IS NOT NULL AND td_gt <> td_spine)
    INTO v_eligible, v_ambiguous, v_disagree
    FROM _tdc;

  IF NOT p_apply THEN
    SELECT count(*) FILTER (WHERE td_now IS NULL AND td_gt IS NOT NULL),
           count(*) FILTER (WHERE td_now IS NULL AND td_gt IS NULL AND td_spine IS NOT NULL),
           count(*) FILTER (WHERE td_now IS NULL AND td_gt IS NULL AND td_spine IS NULL)
      INTO v_gt, v_spine, v_remaining
      FROM _tdc;
    RETURN jsonb_build_object(
      'applied', false, 'note', 'DRY RUN -- nothing written.',
      'horizon_from', v_from::text, 'eligible_orders', v_eligible,
      'would_fill_by_gotickets_identity', v_gt, 'would_fill_by_tevo_spine', v_spine,
      'left_unfilled', v_remaining,
      'of_those_blocked_as_ambiguous', v_ambiguous,
      'route_disagreements', v_disagree,
      'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
  END IF;

  -- PASS 1 -- GoTickets id -> cluster. Exact by PK. Fill-only.
  UPDATE public.s4kcs_orders o
     SET tdev_id = c.td_gt, tdev_mapped_via = 'gotickets_identity', tdev_mapped_at = now()
    FROM _tdc c
   WHERE o.s4k_order_id = c.s4k_order_id AND o.source = c.source
     AND o.tdev_id IS NULL AND c.td_gt IS NOT NULL;
  GET DIAGNOSTICS v_gt = ROW_COUNT;

  -- PASS 2 -- TEvo spine, single cluster only. Never overwrites pass 1, which is why the 7
  -- route disagreements need no special case: the identity answer is already there.
  UPDATE public.s4kcs_orders o
     SET tdev_id = c.td_spine, tdev_mapped_via = 'tevo_spine_unique', tdev_mapped_at = now()
    FROM _tdc c
   WHERE o.s4k_order_id = c.s4k_order_id AND o.source = c.source
     AND o.tdev_id IS NULL AND c.td_gt IS NULL AND c.td_spine IS NOT NULL;
  GET DIAGNOSTICS v_spine = ROW_COUNT;

  SELECT count(*) INTO v_remaining
    FROM public.s4kcs_orders
   WHERE event_date >= v_from AND coalesce(event_name,'') !~* 'parking|shuttle'
     AND tdev_id IS NULL;

  RETURN jsonb_build_object(
    'applied', true, 'horizon_from', v_from::text, 'eligible_orders', v_eligible,
    'filled_by_gotickets_identity', v_gt, 'filled_by_tevo_spine', v_spine,
    'still_unfilled', v_remaining,
    'of_those_blocked_as_ambiguous', v_ambiguous,
    'route_disagreements', v_disagree,
    'elapsed_ms', round(EXTRACT(epoch FROM (clock_timestamp() - v_started)) * 1000));
END $fn$;

REVOKE ALL ON FUNCTION public.s4kcs_link_tickets_dev(boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.s4kcs_link_tickets_dev(boolean, int) TO service_role;

COMMENT ON FUNCTION public.s4kcs_link_tickets_dev(boolean, int) IS
  'Fills s4kcs_orders.tdev_id with the tickets.dev cross-marketplace cluster. Pass 1 from gt_event_id through tickets_dev_source_id (exact -- its PK makes the hop 1:1), pass 2 from the TEvo spine via aq_event_map and ONLY where the hop lands on exactly one cluster; multi-cluster hops are left NULL rather than guessed. Fill-only in both passes, so pass 1 always wins a disagreement. DRY RUN unless p_apply => true. Future-only by default; p_horizon_days widens it. Reads only tables we already hold -- no upstream call, RULE 2 untouched (mig 20260916180000).';

-- ============================================================================================
-- APPLIED AND VERIFIED ON PROD, 2026-09-16 (future orders only)
-- ============================================================================================
--   eligible future non-parking orders          27,713
--   filled by GOTICKETS IDENTITY                15,443
--   filled by TEVO SPINE (single cluster)        4,761
--   still unfilled                               7,509
--     of those, REFUSED as multi-cluster            29
--   route disagreements (pass 1 kept)                7
--   dangling tdev_id (not in the catalogue)          0
--
-- THE DRY RUN RECONCILED TO THE PRE-MEASUREMENT EXACTLY, which is the verification and not a
-- coincidence: 20,233 measured reachable, minus the 29 the function REFUSES because their TEvo
-- event hops to more than one cluster, is 20,204 -- and 15,443 + 4,761 = 20,204. The gap between
-- "reachable" and "filled" is entirely the ambiguity guard, with nothing unaccounted for.
--
--   future CRM orders by what they can now be joined on:
--     evo+ gt+ td+    15,486
--     evo+ gt- td+     4,698   <-- the point of this migration
--     evo+ gt- td-     4,089
--     evo+ gt+ td-     3,197
--     evo- gt+ td+        20   no TEvo id at all, and still cross-marketplace identifiable
--     evo- gt+ td-        16
--     evo- gt- td-       207
--
-- THE 4,698 ARE WHY THIS COLUMN EXISTS. They have no GoTickets id -- 20260916160000 could not
-- reach them and neither could any amount of GoTickets matcher work -- yet they are the same
-- real-world events that Vivid, StubHub or Ticketmaster sell, and the catalogue already knew it.
-- They were reachable the whole time through a table we already held; nothing pointed at it.
-- Add the 20 with no TEvo id whatsoever and 4,718 future orders gain a cross-source join key
-- that no existing route could produce.
--
-- 1,279 DISTINCT CLUSTERS carry all 20,204 linked orders. That concentration is itself the
-- argument for the column: a per-cluster question ("everything we hold on this event, across
-- every marketplace") is now one equality join instead of four id systems reconciled by hand.
--
-- WHAT IS LEFT:
--   * 7,509 unfilled, of which 7,286 (4,089 + 3,197) have a TEvo event the catalogue simply does
--     not carry. The catalogue holds 5,498 future events; our forward book is far larger. This is
--     a coverage gap in an upstream cache, not a mapping defect, and it closes by probing more --
--     tickets_dev_probe already exists for exactly that and shows 4,711 found / 168 not_found.
--   * 29 refused as multi-cluster. Same shape as the 376 GoTickets double-claims: an operator
--     call about which cluster is right, not something this function should guess.
--   * 207 with no identifier of any kind, unchanged by this migration and unreachable by it --
--     they have no TEvo id and no GoTickets id to hop from. 96 of them (SeatGeek 90, TickPick 6)
--     the bridge answers source_not_indexed for, non-retryable (mig 20260914211000).
