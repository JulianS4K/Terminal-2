-- Migration 20261006220000 · level:secondary-sales · lane:D0 · writes:get_event_orders_daily() · reads:v_s4kcs_orders,seatgeek_orders,evo_orders,evo_order_items,order_status_xref,seatgeek_sales_snapshots · pre:20261006180000
--
-- ============================================================================
-- Migration 20261006220000 — event page: our orders from every source + per-day
--
-- Lane:     D0 (terminal event page) · operator-directed 2026-10-06 ("fix
--           event.html tables, data and other to incorporate all available data")
-- Touches:  get_event_orders_daily(bigint, int) (W, new; SECDEF, email-gated)
-- Pre-reqs: 20261006180000 (same order-book sources + exclusions as
--           get_d0_pickups_v2)
--
-- Already applied to prod · via MCP 2026-10-06 ~19:50 UTC under operator
-- direction ("Apply both"), together with get_event_source_links from
-- 20260603180000 (authored June, never applied — the ↗ source chips were dead).
-- Verified: @s4kent.com JWT → 3286330 totals 320 orders / 984 tix / $69,930,
-- 7 daily rows; gmail JWT → 42501.
--
-- WHY: the event page's Our Orders tab shows TEvo orders, our SeatGeek seller
--   orders and a TickPick/Vivid aggregate — but NOT the S4K CRM book
--   (v_s4kcs_orders: StubHub, Gametime, Vivid, TickPick, GoTickets …), which is
--   most of what we sell (audit 2026-10-06: 315 / 289 / 203 CRM orders on three
--   sample events, none rendered). tickpick_orders itself stopped 2026-05-31.
--   Nothing on the page gives a per-day view of our pace next to the market.
--
-- RETURNS jsonb
--   orders  : newest-first rows from all three books (≤ 500): source, order_id,
--             d (ET purchase day), section, row, qty, price (per ticket), total,
--             status (raw), canonical (order_status_xref), cancelled (bool)
--   daily   : per ET day over the last p_days (default 30, 1–365): our orders /
--             tix / sales (non-cancelled), by_source {source: orders}, and the
--             SeatGeek public market that day (distinct sg_sale_id; NULL when
--             the SG feed doesn't cover the event)
--   totals  : orders, tix, sales, cancelled (all time for the event)
--   by_source: {source: {orders, tix, sales}} non-cancelled, all time
--   mkt_tracked: SeatGeek sales feed covers this event
-- Same sources + cancel rules as get_d0_pickups_v2: CRM minus its SeatGeek rows
-- (those come from seatgeek_orders), SeatGeek seller orders, TEvo order items.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_event_orders_daily(p_event_id bigint, p_days int DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_email  text := coalesce(auth.jwt()->>'email', '');
  v_days   int  := greatest(1, least(coalesce(p_days, 30), 365));
  v_today  date := (now() AT TIME ZONE 'America/New_York')::date;
  v_out    jsonb;
BEGIN
  -- SECDEF: current_user is the owner here, so gate on the caller's JWT role/email.
  IF coalesce(auth.role(), '') <> 'service_role' AND v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH o AS (
    SELECT v.source, v.s4k_order_id::text AS order_id, v.purchase_date::date AS d,
           v.section, v.row, coalesce(v.quantity, 0) AS qty,
           v.price_per_ticket AS price,
           coalesce(v.price_per_ticket, 0) * greatest(coalesce(v.quantity, 1), 1) AS total,
           v.order_status AS status, x.canonical_status AS canonical
    FROM v_s4kcs_orders v
    LEFT JOIN order_status_xref x ON x.source = 's4kcs' AND x.source_status = v.order_status
    WHERE v.tevo_event_id = p_event_id AND v.source <> 'SeatGeek'
    UNION ALL
    SELECT 'SeatGeek', s.sg_order_id::text, (s.created_at_sg AT TIME ZONE 'America/New_York')::date,
           s.sale_section, s.sale_row, coalesce(s.sale_quantity, 0),
           CASE WHEN coalesce(s.sale_quantity, 0) > 0 THEN round(s.payment_total / s.sale_quantity, 2) END,
           coalesce(s.payment_total, 0), s.status, x.canonical_status
    FROM seatgeek_orders s
    LEFT JOIN order_status_xref x ON x.source = 'seatgeek' AND x.source_status = s.status
    WHERE s.tevo_event_id = p_event_id
    UNION ALL
    SELECT 'TEvo', e.evo_order_id::text, (e.evo_created_at AT TIME ZONE 'America/New_York')::date,
           i.ticket_group_section, i.ticket_group_row, coalesce(i.quantity, 0),
           i.price, coalesce(i.price * i.quantity, 0), e.state, x.canonical_status
    FROM evo_order_items i
    JOIN evo_orders e USING (evo_order_id)
    LEFT JOIN order_status_xref x ON x.source = 'evo' AND x.source_status = e.state
    WHERE i.event_id = p_event_id
  ),
  oc AS (
    SELECT o.*, coalesce(o.canonical, 'accepted') IN ('cancelled', 'rejected') AS cancelled FROM o
  ),
  mkt_raw AS (
    SELECT DISTINCT ON (s.sg_sale_id) (s.sale_at_utc AT TIME ZONE 'America/New_York')::date AS d,
           coalesce(s.quantity, 0) AS q
    FROM seatgeek_sales_snapshots s
    WHERE s.tevo_event_id = p_event_id
      AND s.sale_at_utc >= ((v_today - v_days + 1)::timestamp AT TIME ZONE 'America/New_York')
    ORDER BY s.sg_sale_id, s.pulled_at DESC
  ),
  mkt AS (SELECT d, count(*)::int AS n, sum(q)::int AS tix FROM mkt_raw GROUP BY d),
  tracked AS (
    SELECT EXISTS (SELECT 1 FROM seatgeek_sales_snapshots s WHERE s.tevo_event_id = p_event_id) AS t
  ),
  days AS (SELECT generate_series(v_today - v_days + 1, v_today, interval '1 day')::date AS d),
  ours AS (
    SELECT d, count(*)::int AS orders, sum(qty)::int AS tix, round(sum(total), 2) AS sales
    FROM oc WHERE NOT cancelled AND d >= v_today - v_days + 1 GROUP BY d
  ),
  ours_src AS (
    SELECT d, jsonb_object_agg(source, n) AS by_source
    FROM (SELECT d, source, count(*)::int AS n FROM oc
          WHERE NOT cancelled AND d >= v_today - v_days + 1 GROUP BY d, source) z
    GROUP BY d
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id,
    'days', v_days,
    'mkt_tracked', (SELECT t FROM tracked),
    'totals', (SELECT jsonb_build_object(
                 'orders',    count(*) FILTER (WHERE NOT cancelled),
                 'tix',       coalesce(sum(qty) FILTER (WHERE NOT cancelled), 0),
                 'sales',     round(coalesce(sum(total) FILTER (WHERE NOT cancelled), 0), 2),
                 'cancelled', count(*) FILTER (WHERE cancelled)) FROM oc),
    'by_source', coalesce((SELECT jsonb_object_agg(source, jsonb_build_object('orders', n, 'tix', t, 'sales', s))
                           FROM (SELECT source, count(*)::int n, sum(qty)::int t, round(sum(total), 2) s
                                 FROM oc WHERE NOT cancelled GROUP BY source) z), '{}'::jsonb),
    'daily', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                 'd', dd.d,
                 'orders', coalesce(ou.orders, 0),
                 'tix', coalesce(ou.tix, 0),
                 'sales', coalesce(ou.sales, 0),
                 'by_source', coalesce(os.by_source, '{}'::jsonb),
                 'mkt_sales', CASE WHEN (SELECT t FROM tracked) THEN coalesce(m.n, 0) END,
                 'mkt_tix',   CASE WHEN (SELECT t FROM tracked) THEN coalesce(m.tix, 0) END
               ) ORDER BY dd.d), '[]'::jsonb)
              FROM days dd
              LEFT JOIN ours ou ON ou.d = dd.d
              LEFT JOIN ours_src os ON os.d = dd.d
              LEFT JOIN mkt m ON m.d = dd.d),
    'orders', (SELECT coalesce(jsonb_agg(r ORDER BY r.d DESC NULLS LAST, r.order_id DESC), '[]'::jsonb)
               FROM (SELECT source, order_id, d, section, "row", qty, price, round(total, 2) AS total,
                            status, canonical, cancelled
                     FROM oc ORDER BY d DESC NULLS LAST, order_id DESC LIMIT 500) r)
  ) INTO v_out;

  RETURN v_out;
END
$func$;

REVOKE ALL ON FUNCTION public.get_event_orders_daily(bigint, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_event_orders_daily(bigint, int) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_event_orders_daily(bigint, int) IS
  'D0 event page: our orders on one event from every book (S4K CRM minus its SG rows, SeatGeek seller orders, TEvo items) — rows, totals, by-source, and per-ET-day pace next to SeatGeek public market sales (distinct sg_sale_id). @s4kent.com email-gated. Mig 20261006220000.';
