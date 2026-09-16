-- Migration 20260917010000 · level:read-surface · lane:A1 (RPC) + D0/D7 consumers · writes:get_event_gotickets_bridge() fn, v_n2s_orders view (+2 columns) · reads:gotickets_event, aq_event_map, gotickets_sales, gotickets_purchases, gotickets_listings_snapshots, s4kcs_orders, n2s_items · pre:20260917000000
--
-- ============================================================================================
-- THE TERMINAL SHOWED GOTICKETS PRICES FOR AN EVENT BUT NEVER WHICH GOTICKETS EVENT IT WAS
-- ============================================================================================
-- The event page already draws the GoTickets (GOT) median and listing-count series, the Deals
-- feed links out to gotickets.com, and Subs carries a GoTickets buy link per cover. What none
-- of them show is the MAPPING: which GoTickets event this TEvo event is, whether that mapping
-- is clean or double-claimed, and what we hold on it. After 2026-09-16 that answer exists on
-- 1,718 of the 1,927 future events we hold orders on, and no surface asked for it.
--
-- Operator 2026-09-16: "wire the html in terminal 2 so gotickets wires in."
--
-- ONE SMALL RPC, NOT A CHANGE TO get_broker_event_page_v3. v3 is a 9.5 KB wrapper over v2 and
-- every page load runs it; a mapping lookup is a separate concern and a separate call, the
-- same shape as get_event_face and get_gotickets_event_series -- fire-and-forget from the page,
-- self-hiding when there is nothing to say. Touching v3 for this would put a drift surface on
-- the heaviest RPC in the terminal for a chip.
--
-- THE RESOLUTION RULE IS THE ONE EVERY LINKER TODAY USES, and it is reported, not hidden:
--   spine_single   exactly one gotickets_event row claims this TEvo event
--   aq_single      the mirror has none, the hub has exactly one distinct id
--   double_claim   more than one gotickets_event row claims it -- the 235; the page SAYS so
--                  rather than picking one, because a wrong deep link is worse than none
--   none           nothing anywhere
-- Measured on future events with CRM orders: 1,200 spine_single, 518 aq_single, 27 double,
-- 206 none.
--
-- SUBS: v_n2s_orders gains gt_event_id + gt_mapped_via at the END of its column list (CREATE OR
-- REPLACE VIEW permits appending, nothing else), the endpoint selects them, the row links out.
-- The obligation already carried a buy link for its COVER; now it also says which GoTickets
-- event the SOLD ticket belongs to, which is the thing you check before covering.
-- ============================================================================================

CREATE OR REPLACE FUNCTION public.get_event_gotickets_bridge(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email     text;
  v_gt        bigint;
  v_via       text;
  v_claimants int;
  v_aq_ids    int;
  v_sales     jsonb;
  v_purch     jsonb;
  v_snap_at   timestamptz;
  v_crm       jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT count(*), CASE WHEN count(*) = 1 THEN min(gt_event_id) END
    INTO v_claimants, v_gt
    FROM public.gotickets_event WHERE tevo_event_id = p_event_id;

  IF v_claimants = 1 THEN
    v_via := 'spine_single';
  ELSIF v_claimants > 1 THEN
    v_via := 'double_claim';
  ELSE
    SELECT count(DISTINCT gotickets_event_id), CASE WHEN count(DISTINCT gotickets_event_id) = 1 THEN min(gotickets_event_id) END
      INTO v_aq_ids, v_gt
      FROM public.aq_event_map WHERE tevo_event_id = p_event_id AND gotickets_event_id IS NOT NULL;
    v_via := CASE WHEN v_aq_ids = 1 THEN 'aq_single' WHEN v_aq_ids > 1 THEN 'aq_conflict' ELSE 'none' END;
  END IF;

  IF v_gt IS NOT NULL THEN
    SELECT jsonb_build_object('count', count(*), 'qty', coalesce(sum(quantity), 0),
                              'payout', coalesce(sum(total_payout), 0), 'last_sale_at', max(create_time))
      INTO v_sales FROM public.gotickets_sales WHERE gt_event_id = v_gt;
    SELECT jsonb_build_object('count', count(*), 'qty', coalesce(sum(quantity), 0))
      INTO v_purch FROM public.gotickets_purchases WHERE gt_event_id = v_gt;
  END IF;

  SELECT max(captured_at) INTO v_snap_at
    FROM public.gotickets_listings_snapshots WHERE tevo_event_id = p_event_id;

  SELECT jsonb_build_object('count', count(*), 'with_gt', count(*) FILTER (WHERE gt_event_id IS NOT NULL))
    INTO v_crm
    FROM public.s4kcs_orders
   WHERE tevo_event_id = p_event_id AND coalesce(event_name, '') !~* 'parking|shuttle';

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id,
    'gt_event_id', v_gt,
    'resolved_via', v_via,
    'claimants', v_claimants,
    'gt_url', CASE WHEN v_gt IS NOT NULL THEN 'https://gotickets.com/tickets/' || v_gt::text END,
    'our_sales', coalesce(v_sales, jsonb_build_object('count', 0, 'qty', 0, 'payout', 0, 'last_sale_at', NULL)),
    'our_purchases', coalesce(v_purch, jsonb_build_object('count', 0, 'qty', 0)),
    'listings_latest_at', v_snap_at,
    'crm_orders', v_crm
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_event_gotickets_bridge(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_gotickets_bridge(bigint) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_gotickets_bridge(bigint) IS
  'Event page: which GoTickets event this TEvo event is (single claimant via the mirror, else the hub), reported with HOW it resolved -- double_claim and none are answers, not blanks -- plus our GoTickets sales/purchases on it, listing-snapshot freshness, and CRM order coverage. Read-only, @s4kent.com gated (mig 20260917010000).';

-- Subs: expose the obligation's own GoTickets link. Column list is the live definition verbatim
-- with the two new columns appended at the end; CREATE OR REPLACE VIEW keeps grants.
CREATE OR REPLACE VIEW public.v_n2s_orders AS
 SELECT n.n2s_id,
    n.order_number,
    n.s4k_source,
    n.status AS n2s_status,
    n.status_label,
    n.fail_reason,
    n.timer_expired,
    n.alert_at,
    n.timer_expires_at,
    n.event_name,
    n.event_dt::date AS event_date,
    n.event_dt,
    n.venue,
    n.tevo_event_id,
    n.mapped_via,
    n.sources_pulled_at,
    n.section,
    n."row" AS order_row,
    n.qty AS quantity,
    n.price_per_ticket AS sold_ea,
    n.grand_total AS sold_total,
    c.sub_source,
    c.sub_listing_id,
    c.sub_section,
    c.sub_row,
    c.sub_qty,
    c.sub_ea,
    c.sub_total,
    c.cover_cost,
    c.rows_closer,
    c.buy_url,
    c.captured_at,
    c.cover_rank,
    c.fifo_position,
    c.refreshed_at,
    c.n2s_id IS NOT NULL AS has_cover,
        CASE
            WHEN c.n2s_id IS NOT NULL THEN NULL::text
            WHEN n.tevo_event_id IS NULL THEN 'unmapped'::text
            WHEN NOT (EXISTS ( SELECT 1
               FROM events e
              WHERE e.id = n.tevo_event_id)) THEN 'event_not_catalogued'::text
            WHEN n.sources_pulled_at IS NULL THEN 'awaiting_source_pull'::text
            ELSE 'no_match'::text
        END AS no_cover_reason,
    b.intent_id AS open_intent_id,
    b.requested_by AS open_intent_by,
    c.sub_avail,
    n.n2s_order_key,
    c.cover_gate,
    c.cover_label,
    c.order_zone,
    c.sub_zone,
    c.sub_notes,
    c.sub_view,
    n.gt_event_id,
    n.gt_mapped_via
   FROM n2s_items n
     LEFT JOIN n2s_cover_queue c ON c.n2s_id = n.n2s_id
     LEFT JOIN n2s_buy_intent b ON b.n2s_id = n.n2s_id AND b.status = 'requested'::text
  WHERE NOT n.is_terminal AND n2s_event_live(n.event_dt, n.tevo_event_id);
