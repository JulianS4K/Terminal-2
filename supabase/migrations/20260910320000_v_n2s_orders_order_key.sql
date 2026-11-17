-- ============================================================================
-- Migration 20260910320000 — carry the source order key onto the panel
--
-- Lane:     D0 (orders surface)
-- Touches:  v_n2s_orders (CREATE OR REPLACE VIEW — n2s_order_key APPENDED).
-- Pre-reqs: 20260910190000
--
-- READ-ONLY upstream: no API call. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "also include the src order number in view so
-- we can look up order in real time."
--
-- ── WHAT WAS MISSING, AND WHAT WAS NOT ────────────────────────────────────
-- order_number was already in the view AND already in the API response — the
-- gap was purely that the covers table never rendered it. The panel showed
-- WHICH MARKETPLACE failed but not WHICH ORDER, so there was nothing to paste
-- into that marketplace's console while the obligation was still live. That
-- half of the fix is a column in subs.js and needs no schema change.
--
-- What genuinely was missing is n2s_order_key, and it matters for exactly one
-- source. Measured across the open book:
--
--   Gametime / Vivid / StubHub / TickPick / GoTickets / SeatGeek
--       order_number == n2s_order_key (identical, nothing to disambiguate)
--   EVO order_number = '8047273-19083928'  <- invoice-order composite
--       n2s_order_key = '19083928'         <- the order id on its own
--
-- Pasting the composite where the console wants the order id finds nothing,
-- and the operator has no way to know from the panel that the string is two
-- identifiers glued together. The view now carries both so the panel can show
-- the second line only when it actually differs — which is EVO and nowhere
-- else, so no other row gains noise.
--
-- ⚠ APPENDED, NOT INSERTED. CREATE OR REPLACE VIEW can only add columns at the
-- END; reordering requires a DROP, which would cascade to every dependent.
-- n2s_order_key therefore sits after sub_avail (itself appended by
-- 20260910250000) rather than next to order_number where it reads better.
-- ============================================================================

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
            WHEN n.sources_pulled_at IS NULL THEN 'awaiting_source_pull'::text
            ELSE 'no_match'::text
        END AS no_cover_reason,
    b.intent_id AS open_intent_id,
    b.requested_by AS open_intent_by,
    c.sub_avail,
    n.n2s_order_key
   FROM n2s_items n
     LEFT JOIN n2s_cover_queue c ON c.n2s_id = n.n2s_id
     LEFT JOIN n2s_buy_intent b ON b.n2s_id = n.n2s_id AND b.status = 'requested'::text
  WHERE NOT n.is_terminal AND n.event_dt::date >= CURRENT_DATE;
