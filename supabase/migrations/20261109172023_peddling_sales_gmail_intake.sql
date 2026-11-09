-- Migration 20261109172023 · level:secondary-sales · lane:D0 · writes:peddling_sales,peddling_sales_ingest_from_apps_script · reads:vault(APPSCRIPT_INGEST_SECRET) · pre:20260515120000
--
-- Already applied to prod · via MCP 2026-11-09 (operator-approved; recorded as version 20261109172023)
--
-- ============================================================================
-- Migration 20261109172023 — peddling sales ledger fed from Gmail (Apps Script)
--
-- Lane:     D0 (orders)
-- Touches:  peddling_sales (W), get_app_secret (R, existing allowlist entry)
-- Pre-reqs: 20260515120000 (APPSCRIPT_INGEST_SECRET in get_app_secret's allowlist
--           + vault), scripts/apps_script/peddling_sales_sync.gs installed in
--           one or more inboxes
--
-- WHAT: every "[PACIOLAN] PEDDLING SALE RECEIVED" email (orders@s4kent.com) is
-- a sale we made. scripts/apps_script/peddling_sales_sync.gs parses each one,
-- appends it to the operator's Google Sheet, and upserts it here — one row per
-- sale, keyed on our order number (the email's "Order #", the sheet's
-- "Invoice #"). Unlike n2b_ingest_from_apps_script (mig 20261009180000), which
-- only takes Need2Buy/WaitToBuy-labelled threads and feeds the N2S pricing
-- pipeline, this is a plain ledger of EVERY peddled sale and changes nothing
-- downstream.
--
-- The script can run in several inboxes at once; the upsert is idempotent and
-- `mailbox` keeps the inbox that reported the sale first. `cancelled` is
-- sticky (once a thread carries a CANCEL email it stays cancelled).
--
-- AUTH: same pattern as tickpick_orders_ingest_from_apps_script /
-- n2b_ingest_from_apps_script — callable with the anon key (Apps Script has no
-- service role), gated on the vault secret APPSCRIPT_INGEST_SECRET. The table
-- has RLS on and no policies: only this SECURITY DEFINER RPC writes it, and
-- only service_role reads it. Nothing upstream is called.
-- ============================================================================

-- 1. table ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.peddling_sales (
  pos_order        bigint PRIMARY KEY,           -- email "Order #" / sheet "Invoice #"
  source           text NOT NULL DEFAULT 'PACIOLAN',
  site             text,                         -- marketplace, e.g. Viagogo
  site_order       text,                         -- marketplace order id
  sale_dt          timestamp,                    -- "Sale Date", as printed (no zone)
  email_at         timestamptz,                  -- Gmail message timestamp
  tnow_ticket      text,
  tu_ticket        text,
  event_name       text,
  venue            text,
  event_dt         timestamp,                    -- "Event Date", venue-local (no zone)
  section          text,
  "row"            text,
  seats            text,                         -- raw, e.g. "3-5"
  seat_start       text,
  seat_end         text,
  qty              integer,
  price_each       numeric(12,2),
  total            numeric(12,2),
  cancelled        boolean NOT NULL DEFAULT false,
  mailbox          text,                         -- inbox that reported it first
  gmail_message_id text,
  gmail_thread_id  text,
  raw              jsonb NOT NULL DEFAULT '{}'::jsonb,
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS peddling_sales_event_dt_idx ON public.peddling_sales (event_dt);
CREATE INDEX IF NOT EXISTS peddling_sales_site_order_idx ON public.peddling_sales (site, site_order);

ALTER TABLE public.peddling_sales ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.peddling_sales FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.peddling_sales TO service_role;

COMMENT ON TABLE public.peddling_sales IS
  'Ledger of every Gmail "PEDDLING SALE RECEIVED" sale, one row per our order number. Written only by peddling_sales_ingest_from_apps_script (scripts/apps_script/peddling_sales_sync.gs). Mig 20261109172023.';

-- 2. intake RPC -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.peddling_sales_ingest_from_apps_script(
  p_items jsonb, p_shared_secret text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expected text := public.get_app_secret('APPSCRIPT_INGEST_SECRET');
  v_total int;
  v_new int := 0; v_upd int := 0;
BEGIN
  IF v_expected IS NULL OR v_expected = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_items);
  IF v_total > 2000 THEN
    RAISE EXCEPTION 'p_items too large (% > 2000)', v_total USING ERRCODE = '22023';
  END IF;

  WITH src AS (
    -- one row per order even if a batch repeats one
    SELECT DISTINCT ON ((it->>'pos_order')::bigint)
           (it->>'pos_order')::bigint AS pos_order, it
      FROM jsonb_array_elements(p_items) AS it
     WHERE it->>'pos_order' ~ '^[0-9]{1,15}$'
     ORDER BY (it->>'pos_order')::bigint
  ),
  up AS (
    INSERT INTO public.peddling_sales AS t (
      pos_order, source, site, site_order, sale_dt, email_at, tnow_ticket, tu_ticket,
      event_name, venue, event_dt, section, "row", seats, seat_start, seat_end,
      qty, price_each, total, cancelled, mailbox, gmail_message_id, gmail_thread_id,
      raw, first_seen_at, updated_at)
    SELECT
      s.pos_order,
      COALESCE(NULLIF(btrim(s.it->>'source'), ''), 'PACIOLAN'),
      NULLIF(btrim(s.it->>'site'), ''),
      NULLIF(btrim(s.it->>'site_order'), ''),
      CASE WHEN s.it->>'sale_dt'  ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' THEN (s.it->>'sale_dt')::timestamp END,
      CASE WHEN s.it->>'email_at' ~ '^\d{4}-\d{2}-\d{2}T' THEN (s.it->>'email_at')::timestamptz END,
      NULLIF(btrim(s.it->>'tnow_ticket'), ''),
      NULLIF(btrim(s.it->>'tu_ticket'), ''),
      NULLIF(btrim(s.it->>'event_name'), ''),
      NULLIF(btrim(s.it->>'venue'), ''),
      CASE WHEN s.it->>'event_dt' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' THEN (s.it->>'event_dt')::timestamp END,
      NULLIF(btrim(s.it->>'section'), ''),
      NULLIF(btrim(s.it->>'row'), ''),
      NULLIF(btrim(s.it->>'seats'), ''),
      NULLIF(btrim(s.it->>'seat_start'), ''),
      NULLIF(btrim(s.it->>'seat_end'), ''),
      CASE WHEN s.it->>'qty' ~ '^\d{1,6}$' THEN (s.it->>'qty')::integer END,
      CASE WHEN s.it->>'price_each' ~ '^\d+(\.\d+)?$' THEN (s.it->>'price_each')::numeric END,
      CASE WHEN s.it->>'total'      ~ '^\d+(\.\d+)?$' THEN (s.it->>'total')::numeric END,
      COALESCE((s.it->>'cancelled')::boolean, false),
      NULLIF(btrim(s.it->>'mailbox'), ''),
      NULLIF(btrim(s.it->>'gmail_message_id'), ''),
      NULLIF(btrim(s.it->>'gmail_thread_id'), ''),
      s.it, now(), now()
    FROM src s
    ON CONFLICT (pos_order) DO UPDATE SET
      source           = EXCLUDED.source,
      site             = COALESCE(EXCLUDED.site, t.site),
      site_order       = COALESCE(EXCLUDED.site_order, t.site_order),
      sale_dt          = COALESCE(EXCLUDED.sale_dt, t.sale_dt),
      email_at         = COALESCE(t.email_at, EXCLUDED.email_at),
      tnow_ticket      = COALESCE(EXCLUDED.tnow_ticket, t.tnow_ticket),
      tu_ticket        = COALESCE(EXCLUDED.tu_ticket, t.tu_ticket),
      event_name       = COALESCE(EXCLUDED.event_name, t.event_name),
      venue            = COALESCE(EXCLUDED.venue, t.venue),
      event_dt         = COALESCE(EXCLUDED.event_dt, t.event_dt),
      section          = COALESCE(EXCLUDED.section, t.section),
      "row"            = COALESCE(EXCLUDED."row", t."row"),
      seats            = COALESCE(EXCLUDED.seats, t.seats),
      seat_start       = COALESCE(EXCLUDED.seat_start, t.seat_start),
      seat_end         = COALESCE(EXCLUDED.seat_end, t.seat_end),
      qty              = COALESCE(EXCLUDED.qty, t.qty),
      price_each       = COALESCE(EXCLUDED.price_each, t.price_each),
      total            = COALESCE(EXCLUDED.total, t.total),
      cancelled        = t.cancelled OR EXCLUDED.cancelled,          -- sticky
      mailbox          = COALESCE(t.mailbox, EXCLUDED.mailbox),      -- first inbox wins
      gmail_message_id = COALESCE(t.gmail_message_id, EXCLUDED.gmail_message_id),
      gmail_thread_id  = COALESCE(t.gmail_thread_id, EXCLUDED.gmail_thread_id),
      raw              = EXCLUDED.raw,
      updated_at       = now()
    RETURNING (xmax = 0) AS is_new
  )
  SELECT count(*) FILTER (WHERE is_new), count(*) FILTER (WHERE NOT is_new)
    INTO v_new, v_upd
    FROM up;

  RETURN jsonb_build_object(
    'received', v_total, 'inserted', COALESCE(v_new, 0), 'updated', COALESCE(v_upd, 0),
    'skipped', v_total - COALESCE(v_new, 0) - COALESCE(v_upd, 0));
END;
$function$;

REVOKE ALL ON FUNCTION public.peddling_sales_ingest_from_apps_script(jsonb, text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.peddling_sales_ingest_from_apps_script(jsonb, text) TO anon, service_role;

COMMENT ON FUNCTION public.peddling_sales_ingest_from_apps_script(jsonb, text) IS
  'Peddling-sales intake from scripts/apps_script/peddling_sales_sync.gs: upserts Gmail "PEDDLING SALE RECEIVED" sales into peddling_sales keyed on our order number. cancelled is sticky; mailbox keeps the first inbox. Secret-gated on APPSCRIPT_INGEST_SECRET (20261109172023).';

-- rollback:
--   DROP FUNCTION public.peddling_sales_ingest_from_apps_script(jsonb, text);
--   DROP TABLE public.peddling_sales;
