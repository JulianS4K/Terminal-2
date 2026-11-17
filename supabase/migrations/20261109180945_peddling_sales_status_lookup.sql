-- Migration 20261109180945 · level:secondary-sales · lane:D0 · writes:peddling_sales,peddling_sales_status_from_apps_script · reads:s4kcs_orders,vault(APPSCRIPT_INGEST_SECRET) · pre:20261109174437
--
-- Already applied to prod · via MCP 2026-11-09 (operator-approved; recorded as version 20261109180945)
--
-- ============================================================================
-- Migration 20261109180945 — current marketplace status for every sheet row
--
-- Lane:     D0 (orders)
-- Touches:  peddling_sales (W: market_status, enriched_at), s4kcs_orders (R)
-- Pre-reqs: 20261109174437 (peddling_sales.market_status)
--
-- WHY: the ingest RPC only refreshes the sales the Apps Script re-reads from
-- Gmail (last 3 days), so a sale's Status froze once its email aged out. The
-- operator wants Status kept current for EVERY order in the sheet.
--
-- WHAT: peddling_sales_status_from_apps_script(p_rows, p_shared_secret).
-- The script sends every sheet row's {invoice, site_order, qty}; for each it
-- returns the marketplace order's CURRENT status from s4kcs_orders (A1's
-- order book, refreshed every few minutes), matched on the marketplace order
-- id (+ quantity when both know it) — the same rule as peddling_sales_enrich.
-- A sale we have in peddling_sales uses its stored site_order/qty and gets
-- its market_status updated; a row typed into the sheet by hand (not in
-- peddling_sales) is matched on the Site Order # the sheet gives. A sale
-- whose email had a CANCEL message reads 'Cancelled'.
--
-- Indexed lookups only (s4kcs_orders_order_id_idx) — deliberately NOT a call
-- to peddling_sales_enrich, whose venue fallback scans s4kcs_orders by venue
-- name and is too heavy to repeat for the whole sheet every 5 minutes.
--
-- AUTH: anon-callable, gated on APPSCRIPT_INGEST_SECRET like the ingest RPC.
-- Returns status strings only — no customer data.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.peddling_sales_status_from_apps_script(
  p_rows jsonb, p_shared_secret text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expected text := public.get_app_secret('APPSCRIPT_INGEST_SECRET');
  v_total int;
  v_rows jsonb;
  v_changed int;
BEGIN
  IF v_expected IS NULL OR v_expected = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_rows);
  IF v_total > 5000 THEN
    RAISE EXCEPTION 'p_rows too large (% > 5000)', v_total USING ERRCODE = '22023';
  END IF;

  WITH inp AS (
    SELECT DISTINCT ON (btrim(r->>'invoice'))
           btrim(r->>'invoice')                       AS invoice,
           NULLIF(btrim(r->>'site_order'), '')        AS site_order,
           CASE WHEN btrim(r->>'qty') ~ '^\d{1,6}$' THEN btrim(r->>'qty')::int END AS qty
      FROM jsonb_array_elements(p_rows) r
     WHERE btrim(r->>'invoice') ~ '^[0-9]{1,15}$'
     ORDER BY btrim(r->>'invoice')
  ),
  j AS (
    SELECT inp.invoice, p.pos_order, COALESCE(p.cancelled, false) AS cancelled,
           COALESCE(p.site_order, inp.site_order) AS so,
           COALESCE(p.qty, inp.qty)               AS q
      FROM inp
      LEFT JOIN public.peddling_sales p ON p.pos_order = inp.invoice::bigint
  ),
  m AS (
    SELECT j.*, s.order_status
      FROM j
      LEFT JOIN LATERAL (
        SELECT s.order_status FROM public.s4kcs_orders s
         WHERE j.so IS NOT NULL AND s.s4k_order_id = j.so
           AND (s.quantity IS NULL OR j.q IS NULL OR s.quantity = j.q)
         ORDER BY s.last_seen_at DESC NULLS LAST
         LIMIT 1) s ON true
  ),
  upd AS (
    UPDATE public.peddling_sales t
       SET market_status = m.order_status, enriched_at = now()
      FROM m
     WHERE t.pos_order = m.pos_order
       AND m.order_status IS NOT NULL
       AND t.market_status IS DISTINCT FROM m.order_status
    RETURNING t.pos_order
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'invoice', m.invoice,
           'status',  CASE WHEN m.cancelled THEN 'Cancelled' ELSE m.order_status END)
           ORDER BY m.invoice)
           FILTER (WHERE m.cancelled OR m.order_status IS NOT NULL), '[]'::jsonb),
         (SELECT count(*) FROM upd)
    INTO v_rows, v_changed
    FROM m;

  RETURN jsonb_build_object('received', v_total, 'with_status', jsonb_array_length(v_rows),
                            'db_changed', v_changed, 'rows', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.peddling_sales_status_from_apps_script(jsonb, text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.peddling_sales_status_from_apps_script(jsonb, text) TO anon, service_role;

COMMENT ON FUNCTION public.peddling_sales_status_from_apps_script(jsonb, text) IS
  'Current marketplace status (s4kcs_orders.order_status, matched on marketplace order id + qty) for every sheet row the peddling Apps Script sends ({invoice, site_order, qty}); refreshes peddling_sales.market_status on the way. Status strings only, no customer data. Secret-gated on APPSCRIPT_INGEST_SECRET (20261109180945).';

NOTIFY pgrst, 'reload schema';

-- rollback:
--   DROP FUNCTION public.peddling_sales_status_from_apps_script(jsonb, text);
