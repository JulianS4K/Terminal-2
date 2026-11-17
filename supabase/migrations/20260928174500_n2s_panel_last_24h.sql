-- Migration 20260928174500 · level:secondary-sales · lane:D7 · writes:v_n2s_orders,v_n2s_orders_live,n2s_cover_push_queue,n2s_profitable_cover_sync,n2s_book_snapshot_take · reads:n2s_items,n2s_cover_queue,n2s_cover_history,n2s_buy_intent · pre:20260928153000
--
-- Already applied to prod · via MCP 2026-09-28 ~17:55 UTC under operator direction
-- ("why aren't orders populating in subs.html" → chose "panel shows last 24h"),
-- after a rolled-back dry run (panel 125 rows in 121 ms; v_n2s_orders_live
-- identical to the old view by md5; the three repointed functions ran clean).
--
-- ============================================================================
-- The subs panel shows the last 24 hours of orders again; Albert's feed stays
-- live-only.
--
-- Since 20260927020000 `v_n2s_orders` only returned orders inside their
-- 10-minute work window, and it is read by BOTH the panel
-- (/api/broker/n2s-covers) and the external feed (n2s_profitable_cover_sync,
-- n2s_cover_push_queue) plus the hourly exposure snapshot. So the panel was
-- empty whenever no order was in its first 10 minutes — 78 minutes on a
-- Monday afternoon (2026-09-28 16:09–17:27 UTC) when the operator asked why
-- no orders showed. Operator chose: panel = last 24 h, feed unchanged.
--
-- CHANGE
--   * v_n2s_orders_live — the previous v_n2s_orders, verbatim (open, event
--     live, inside the 10-minute window). The feed functions and the book
--     snapshot now read this, so their behaviour does not change.
--   * v_n2s_orders (panel) — same columns in the same order, plus:
--       rows: everything v_n2s_orders_live returns, OR any non-terminal order
--             alerted in the last 24 h (even after its window or event ended;
--             measured: 125 such orders in the 24 h to 17:40 UTC, of which 92
--             were for events more than 4 h past start and so hidden by
--             n2s_event_live);
--       no_cover_reason 'window_closed' for a closed-window order (polling and
--             cover search stop at 10 minutes, so it has no current cover);
--       trailing columns in_window, event_live and last_* — the order's most
--             recent cover from n2s_cover_history, so a closed order still
--             shows what we found for it.
-- The three function repoints are md5-guarded text replacements.
-- ============================================================================

-- 1. the old view, verbatim, under a new name
CREATE OR REPLACE VIEW public.v_n2s_orders_live AS
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
    (n.event_dt)::date AS event_date,
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
    (c.n2s_id IS NOT NULL) AS has_cover,
        CASE
            WHEN (c.n2s_id IS NOT NULL) THEN NULL::text
            WHEN (n.tevo_event_id IS NULL) THEN 'unmapped'::text
            WHEN (NOT (EXISTS ( SELECT 1
               FROM events e
              WHERE (e.id = n.tevo_event_id)))) THEN 'event_not_catalogued'::text
            WHEN (n.sources_pulled_at IS NULL) THEN 'awaiting_source_pull'::text
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
   FROM ((n2s_items n
     LEFT JOIN n2s_cover_queue c ON ((c.n2s_id = n.n2s_id)))
     LEFT JOIN n2s_buy_intent b ON (((b.n2s_id = n.n2s_id) AND (b.status = 'requested'::text))))
  WHERE ((NOT n.is_terminal) AND n2s_event_live(n.event_dt, n.tevo_event_id) AND n2s_timer_open(n.timer_expires_at, n.timer_expired, n.alert_at));

REVOKE ALL ON public.v_n2s_orders_live FROM PUBLIC, anon;
GRANT SELECT ON public.v_n2s_orders_live TO authenticated, service_role;
COMMENT ON VIEW public.v_n2s_orders_live IS
  'Open N2S orders inside their 10-minute work window (the pre-20260928174500 v_n2s_orders). Feeds the external cover feed and the book snapshot; the panel reads v_n2s_orders (last 24 h).';

-- 2. the feed functions and the snapshot read the live view
DO $mig$
DECLARE
  f record; v_def text; v_new text;
BEGIN
  FOR f IN SELECT * FROM (VALUES
      ('public.n2s_cover_push_queue(integer)',    'c9c8a64326212ccac9e7d6518318ddbe'),
      ('public.n2s_profitable_cover_sync()',      'c9cc32f14c8a51c4d787119ab41a630e'),
      ('public.n2s_book_snapshot_take()',         '0acb33f3ae010593998975b87103eaf0')) AS t(sig, md5)
  LOOP
    v_def := pg_get_functiondef(f.sig::regprocedure);
    IF md5(v_def) <> f.md5 THEN
      RAISE EXCEPTION '% changed since this migration was written (md5 %)', f.sig, md5(v_def);
    END IF;
    v_new := regexp_replace(v_def, '\mv_n2s_orders\M', 'v_n2s_orders_live', 'g');
    IF v_new = v_def THEN
      RAISE EXCEPTION '%: no v_n2s_orders reference found', f.sig;
    END IF;
    EXECUTE v_new;
  END LOOP;
END $mig$;

-- 3. the panel view: last 24 h, closed-window orders keep their last cover
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
    (n.event_dt)::date AS event_date,
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
    (c.n2s_id IS NOT NULL) AS has_cover,
        CASE
            WHEN (c.n2s_id IS NOT NULL) THEN NULL::text
            WHEN (NOT w.in_window) THEN 'window_closed'::text
            WHEN (n.tevo_event_id IS NULL) THEN 'unmapped'::text
            WHEN (NOT (EXISTS ( SELECT 1
               FROM events e
              WHERE (e.id = n.tevo_event_id)))) THEN 'event_not_catalogued'::text
            WHEN (n.sources_pulled_at IS NULL) THEN 'awaiting_source_pull'::text
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
    n.gt_mapped_via,
    w.in_window,
    w.event_live,
    h.sub_source      AS last_sub_source,
    h.sub_section     AS last_sub_section,
    h.sub_row         AS last_sub_row,
    h.sub_qty         AS last_sub_qty,
    h.sub_price_each  AS last_sub_ea,
    h.cover_cost      AS last_cover_cost,
    h.cover_label     AS last_cover_label,
    h.observed_at     AS last_cover_at
   FROM n2s_items n
     CROSS JOIN LATERAL (SELECT
         n2s_timer_open(n.timer_expires_at, n.timer_expired, n.alert_at) AS in_window,
         n2s_event_live(n.event_dt, n.tevo_event_id)                     AS event_live) w
     LEFT JOIN n2s_cover_queue c ON ((c.n2s_id = n.n2s_id))
     LEFT JOIN n2s_buy_intent b ON (((b.n2s_id = n.n2s_id) AND (b.status = 'requested'::text)))
     LEFT JOIN LATERAL (SELECT hh.sub_source, hh.sub_section, hh.sub_row, hh.sub_qty,
                               hh.sub_price_each, hh.cover_cost, hh.cover_label, hh.observed_at
                          FROM n2s_cover_history hh
                         WHERE hh.n2s_id = n.n2s_id AND hh.event_kind <> 'gone'
                         ORDER BY hh.observed_at DESC
                         LIMIT 1) h ON true
  WHERE (NOT n.is_terminal)
    AND ((w.event_live AND w.in_window)
         OR COALESCE(n.alert_at, n.n2s_created_at) > now() - interval '24 hours');

COMMENT ON VIEW public.v_n2s_orders IS
  'Subs panel: open N2S orders inside their 10-minute window plus every non-terminal order alerted in the last 24 h. Closed-window rows carry no_cover_reason=window_closed and their most recent cover in last_*. The external feed reads v_n2s_orders_live (20260928174500).';

-- rollback:
--   CREATE OR REPLACE VIEW public.v_n2s_orders AS <section 1 body>;  -- columns
--     in_window .. last_cover_at must be dropped first (DROP VIEW + re-create +
--     re-grant: authenticated/service_role/coworker_readonly/analyst_ro SELECT);
--   repoint the three functions back (v_n2s_orders_live -> v_n2s_orders);
--   DROP VIEW public.v_n2s_orders_live;
