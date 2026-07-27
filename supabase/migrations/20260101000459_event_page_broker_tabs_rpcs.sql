-- Migration 20260517220000 · lane:D0 (author) → A1 (apply) · writes:get_event_evo_orders_full + get_event_sg_seller_orders_full + get_event_cross_broker_orders_full · reads:evo_orders,evo_order_items,seatgeek_orders,seatgeek_event_xref,aq_event_map,tickpick_orders,vivid_orders · pre:20260517180000 · auth:operator-approved 2026-05-17
--
-- D0 Phase 2a tabs (round 2) — 3 broker-account SECDEF RPCs surfacing the
-- "our office" side of the data, complementing the 3 marketplace firehoses
-- already shipped in PR #196 (sg_listings / evo_listings / sg_sales):
--   Tab "Our TEvo Orders"        — evo_orders ⨯ evo_order_items per event
--   Tab "Our SG Sales"           — seatgeek_orders (SellerDirect) per event
--   Tab "Cross-Broker (TP+Vivid)"— tickpick + vivid orders UNION per event
--
-- Source matrix per A1's "D0 tab option matrix" (RESOURCES_BIBLE.md):
--   evo_orders            — our office's /v9/orders pulls, 99.5% tevo_event_id populated
--   seatgeek_orders       — our office's SG SellerDirect, sg_event_id only (bridge via seatgeek_event_xref)
--   tickpick_orders       — broker orders, 14% have direct tevo_event_id (94 distinct events)
--   vivid_orders          — broker orders, 0% have tevo_event_id today; bridge via aq_short_event_id → aq_event_map → sg_event_id → seatgeek_event_xref
--
-- All 3 follow the canonical v3 SECDEF pattern:
--   - SECURITY DEFINER + @s4kent.com email gate
--   - REVOKE ALL FROM PUBLIC; GRANT EXECUTE to anon + authenticated
--   - Hard 500-row cap via greatest(1, least(p_limit, 500))
--   - Order by created/ordered/pulled timestamp DESC ("newest first")
--
-- ## Pending operator apply via apply_migration

-- ============================================================
-- 1. Our TEvo Orders — evo_orders joined with evo_order_items
--    One row per order item; carries order-level context (state,
--    totals, fees, buyer/seller brokerage, hold expiry) alongside
--    item-level (section/row/seats, retail/wholesale).
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_evo_orders_full(
  p_event_id integer,
  p_limit    integer DEFAULT 250
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_rows  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH joined AS (
    SELECT
      o.evo_order_id, o.state, o.type, o.fraud_check_status,
      o.total, o.subtotal, o.tax, o.service_fee, o.shipping, o.additional_expense, o.refunded, o.balance,
      o.buyer_brokerage_id, o.buyer_brokerage_name,
      o.seller_brokerage_id, o.seller_brokerage_name,
      o.client_name,
      o.evo_created_at, o.evo_updated_at,
      o.hold_placed_at, o.hold_expires_at,
      o.invoice_number, o.reference, o.po_number,
      i.evo_item_id,
      i.ticket_group_section,
      i.ticket_group_row,
      i.ticket_group_seats,
      i.ticket_group_quantity,
      i.ticket_group_retail_price,
      i.ticket_group_wholesale_price,
      i.quantity AS item_quantity,
      i.price    AS item_price,
      i.eticket_available, i.eticket_delivery, i.eticket_downloaded_at,
      i.event_name, i.occurs_at, i.venue_name
    FROM public.evo_orders o
    LEFT JOIN public.evo_order_items i ON i.evo_order_id = o.evo_order_id
    WHERE o.tevo_event_id = p_event_id
  )
  SELECT jsonb_build_object(
    'count', count(*),
    'distinct_orders', count(DISTINCT j.evo_order_id),
    'event_id', p_event_id,
    'rows', coalesce(jsonb_agg(to_jsonb(j) ORDER BY j.evo_created_at DESC NULLS LAST, j.evo_order_id DESC, j.evo_item_id), '[]'::jsonb)
  ) INTO v_rows
  FROM (
    SELECT * FROM joined
    ORDER BY evo_created_at DESC NULLS LAST, evo_order_id DESC, evo_item_id
    LIMIT greatest(1, least(p_limit, 500))
  ) j;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_evo_orders_full(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_evo_orders_full(integer, integer) TO anon, authenticated;

-- ============================================================
-- 2. Our SG Sales — seatgeek_orders (our SellerDirect account).
--    No tevo_event_id on this table (0/400 populated) — must
--    bridge via seatgeek_event_xref like the marketplace SG tabs.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_sg_seller_orders_full(
  p_event_id integer,
  p_limit    integer DEFAULT 250
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
  v_rows        jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  IF v_sg_event_id IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'no_sg_bridge', 'count', 0, 'rows', '[]'::jsonb);
  END IF;

  WITH rows0 AS (
    SELECT
      sg_order_id, status, created_at_sg, last_status_at,
      sale_section, sale_row, sale_quantity, sale_price,
      payment_total, payment_price, payment_fees, payment_tax, payment_delivery,
      delivery, delivery_method, stock_type,
      sg_listing_id, sg_event_name, sg_venue, sg_event_date,
      fulfillment_issue_message, pulled_at
    FROM public.seatgeek_orders
    WHERE sg_event_id = v_sg_event_id
  )
  SELECT jsonb_build_object(
    'count', count(*),
    'sg_event_id', v_sg_event_id,
    'event_id', p_event_id,
    'rows', coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.created_at_sg DESC NULLS LAST), '[]'::jsonb)
  ) INTO v_rows
  FROM (
    SELECT * FROM rows0
    ORDER BY created_at_sg DESC NULLS LAST
    LIMIT greatest(1, least(p_limit, 500))
  ) r;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_sg_seller_orders_full(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_sg_seller_orders_full(integer, integer) TO anon, authenticated;

-- ============================================================
-- 3. Cross-Broker Orders — TickPick + Vivid combined.
--    TickPick: filter directly on tevo_event_id (94 distinct events
--    have it populated). Vivid today has 0 tevo_event_id rows (bridge
--    cron not landing data); bridge via aq_short_event_id → aq_event_map
--    → sg_event_id → seatgeek_event_xref. Returns empty Vivid section
--    for events without that 2-hop bridge; that's a separate D2/B1 lane
--    issue to fix the Vivid bridge cron.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_cross_broker_orders_full(
  p_event_id integer,
  p_limit    integer DEFAULT 250
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email          text;
  v_sg_event_id    bigint;
  v_aq_short_ids   text[];
  v_rows           jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Resolve aq_short_event_id(s) for Vivid bridge: tevo_event_id → sg_event_id → aq_event_map
  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  IF v_sg_event_id IS NOT NULL THEN
    SELECT array_agg(DISTINCT aq_short_event_id) INTO v_aq_short_ids
    FROM public.aq_event_map WHERE sg_event_id = v_sg_event_id;
  END IF;

  WITH tp AS (
    SELECT
      'tickpick'::text AS source,
      tp_order_id      AS source_order_id,
      status,
      order_status,
      ordered_at,
      section, row, seat_numbers,
      quantity, total,
      event_name, event_date,
      notes,
      matched_via, match_confidence
    FROM public.tickpick_orders
    WHERE tevo_event_id = p_event_id
  ),
  vv AS (
    SELECT
      'vivid'::text  AS source,
      vivid_order_id AS source_order_id,
      status,
      NULL::text     AS order_status,
      ordered_at,
      section, row,
      NULL::text[]   AS seat_numbers,
      quantity, total,
      event_name, event_date,
      NULL::text     AS notes,
      NULL::text     AS matched_via,
      NULL::numeric  AS match_confidence
    FROM public.vivid_orders
    WHERE (v_aq_short_ids IS NOT NULL AND aq_short_event_id = ANY(v_aq_short_ids))
  ),
  combined AS (
    SELECT * FROM tp UNION ALL SELECT * FROM vv
  )
  SELECT jsonb_build_object(
    'count', count(*),
    'tickpick_count', count(*) FILTER (WHERE source = 'tickpick'),
    'vivid_count',    count(*) FILTER (WHERE source = 'vivid'),
    'event_id',       p_event_id,
    'rows', coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.ordered_at DESC NULLS LAST), '[]'::jsonb)
  ) INTO v_rows
  FROM (
    SELECT * FROM combined
    ORDER BY ordered_at DESC NULLS LAST
    LIMIT greatest(1, least(p_limit, 500))
  ) c;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_cross_broker_orders_full(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_cross_broker_orders_full(integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_evo_orders_full(integer, integer) IS
  'D0 event-page tabs (round 2) — our office TEvo orders ⨯ items per event (capped 500). Email-gated.';

COMMENT ON FUNCTION public.get_event_sg_seller_orders_full(integer, integer) IS
  'D0 event-page tabs (round 2) — our SG SellerDirect orders per event (bridge via seatgeek_event_xref, capped 500). Email-gated.';

COMMENT ON FUNCTION public.get_event_cross_broker_orders_full(integer, integer) IS
  'D0 event-page tabs (round 2) — TickPick + Vivid orders UNION per event (TP direct tevo_event_id; Vivid via aq_event_map bridge, capped 500). Email-gated.';
