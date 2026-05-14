-- Migration 20260515120000 · level:admin · lane:Audit/Push · writes:public.tickpick_orders_ingest_from_apps_script + get_app_secret allowlist + pause cron 126/127 · reads:- · pre:20260513230200,20260514040405
-- Apps Script → Supabase TickPick ingest path.
--
-- TickPick blocks Supabase's egress IP range — the existing pg_net-based
-- pull (tickpick_orders_queue/process, jobid 126/127) returns HTTP 401
-- `[invalid-authorization]` because the partner JWT is bound to an IP
-- allowlist that includes the operator's home/office IP + Google Apps
-- Script's egress range but not AWS/Supabase. Confirmed today via:
--   • httpbin proof that pg_net transmits the Authorization header verbatim
--   • UA-spoof to Google-Apps-Script's UA — still 401
--   • Same 74-char Bearer JWT works from operator's local Python (file
--     vivid_client.py-style) AND from Apps Script UrlFetchApp.fetch
--
-- This migration creates a SECURITY DEFINER RPC that Apps Script can POST
-- to via PostgREST. Auth is via a shared secret stored in vault as
-- APPSCRIPT_INGEST_SECRET. The anon key is sufficient to reach the RPC;
-- the shared-secret check inside the function gates actual data writes.
--
-- The pg_net pull crons (126/127) are paused as part of this migration
-- since they only generate 401 noise. They can be reactivated if
-- TickPick ever allowlists Supabase's egress.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session). Idempotent.

-- ============================================================
-- 1. Extend get_app_secret allowlist to include APPSCRIPT_INGEST_SECRET
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
DECLARE v_value text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'get_app_secret: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;
  IF p_name NOT IN (
    'SEATDATA_API_KEY',
    'TEVO_API_TOKEN',
    'TEVO_SECRET',
    'SEATGEEK_API_TOKEN',
    'TICKPICK_API_TOKEN',
    'VIVID_API_TOKEN',
    'APPSCRIPT_INGEST_SECRET'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name
      USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value
    FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

-- ============================================================
-- 2. The Apps Script ingest RPC
--    Apps Script POSTs an array of TickPick /1.0/orders rows; the function
--    validates the shared secret and UPSERTs into tickpick_orders.
--
--    Returns one row: (inserted int, updated int, skipped int).
-- ============================================================

CREATE OR REPLACE FUNCTION public.tickpick_orders_ingest_from_apps_script(
  p_orders        jsonb,
  p_shared_secret text
)
RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $$
DECLARE
  v_expected_secret text;
  v_total           int;
  v_inserted        int := 0;
  v_updated         int := 0;
  v_skipped         int := 0;
BEGIN
  -- Auth gate
  v_expected_secret := get_app_secret('APPSCRIPT_INGEST_SECRET');
  IF v_expected_secret IS NULL OR v_expected_secret = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected_secret THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;

  -- Shape gate
  IF jsonb_typeof(p_orders) <> 'array' THEN
    RAISE EXCEPTION 'p_orders must be a JSON array' USING ERRCODE = '22P02';
  END IF;

  v_total := jsonb_array_length(p_orders);
  IF v_total = 0 THEN
    RETURN QUERY SELECT 0, 0, 0;
    RETURN;
  END IF;

  WITH src AS (
    SELECT o FROM jsonb_array_elements(p_orders) AS o
  ),
  upserted AS (
    INSERT INTO public.tickpick_orders (
      tp_order_id, event_name, event_date,
      section, row, seat_numbers,
      status, quantity, total, notes, ordered_at,
      pulled_at, last_seen_at, raw
    )
    SELECT
      COALESCE(o->>'order_number', o->>'orderId', o->>'id')::text,
      o->>'event_name',
      NULLIF(o->>'event_date','')::timestamptz,
      o->>'section',
      o->>'row',
      CASE
        WHEN jsonb_typeof(o->'seat_numbers') = 'array'
          THEN ARRAY(SELECT jsonb_array_elements_text(o->'seat_numbers'))
        ELSE NULL
      END,
      o->>'status',
      NULLIF(o->>'quantity','')::int,
      NULLIF(o->>'total','')::numeric,
      o->>'notes',
      NULLIF(COALESCE(o->>'order_date', o->>'created_at', o->>'createdAt'), '')::timestamptz,
      now(), now(), o
    FROM src
    WHERE COALESCE(o->>'order_number', o->>'orderId', o->>'id') IS NOT NULL
    ON CONFLICT (tp_order_id) DO UPDATE SET
      event_name   = EXCLUDED.event_name,
      event_date   = EXCLUDED.event_date,
      section      = EXCLUDED.section,
      row          = EXCLUDED.row,
      seat_numbers = EXCLUDED.seat_numbers,
      status       = EXCLUDED.status,
      quantity     = EXCLUDED.quantity,
      total        = EXCLUDED.total,
      notes        = EXCLUDED.notes,
      ordered_at   = COALESCE(EXCLUDED.ordered_at, public.tickpick_orders.ordered_at),
      last_seen_at = now(),
      raw          = EXCLUDED.raw
    RETURNING (xmax = 0) AS is_new
  )
  SELECT
    count(*) FILTER (WHERE is_new)        ::int,
    count(*) FILTER (WHERE NOT is_new)    ::int
  INTO v_inserted, v_updated
  FROM upserted;

  v_skipped := v_total - v_inserted - v_updated;

  RETURN QUERY SELECT v_inserted, v_updated, v_skipped;
END;
$$;

REVOKE ALL ON FUNCTION public.tickpick_orders_ingest_from_apps_script(jsonb, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.tickpick_orders_ingest_from_apps_script(jsonb, text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.tickpick_orders_ingest_from_apps_script(jsonb, text) IS
  'Apps Script → Supabase ingest path for TickPick orders. Anon-callable but '
  'gated by vault secret APPSCRIPT_INGEST_SECRET (must be passed as '
  'p_shared_secret). UPSERTs the JSONB array into tickpick_orders by '
  'tp_order_id. Returns (inserted, updated, skipped).';

-- ============================================================
-- 3. Pause the pg_net-based pull crons (126/127) — they only return 401.
--    Operator can re-activate if TickPick ever allowlists Supabase egress.
-- ============================================================

DO $$
BEGIN
  PERFORM cron.alter_job(jobid := 126, active := false);
  PERFORM cron.alter_job(jobid := 127, active := false);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'cron.alter_job for 126/127 skipped: %', SQLERRM;
END $$;
