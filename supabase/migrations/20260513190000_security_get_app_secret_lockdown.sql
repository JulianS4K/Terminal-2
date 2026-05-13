-- Migration 20260513190000 · level:security · lane:B1 · writes:get_app_secret · reads:- · pre:20260513000050

-- Lock down public.get_app_secret(text). The function reads decrypted broker
-- tokens out of vault.decrypted_secrets and is SECURITY DEFINER, but its
-- EXECUTE privilege had drifted to anon + authenticated. Combined with the
-- public anon JWT (used by the d2_dashboard + storefront front-ends and
-- printed at /api/d2/config-public), that meant anyone holding the anon key
-- could RPC `get_app_secret('TEVO_API_TOKEN')` and exfiltrate every value
-- on the whitelist.
--
-- Fix matches the convention C1 established in
-- 20260513000050_c1_sd_fns_body_assert.sql and A1 in PR #67:
--   1. CREATE OR REPLACE — body unchanged except a `current_user` guard at
--      the top. Belt-and-suspenders: even if grants drift again, the
--      function rejects non-service_role callers.
--   2. REVOKE EXECUTE FROM PUBLIC + explicit REVOKE FROM anon, authenticated
--      (PUBLIC revokes the pseudo-role but does not strip direct grants).
--   3. GRANT EXECUTE TO service_role only.
--
-- Callers verified safe:
--   - app.py:102 creates the Python supabase client with
--     SUPABASE_SERVICE_ROLE_KEY → connects as service_role.
--   - seatdata_client.py:119 and seatgeek_client.py:83 use that same `db`
--     handle for their vault fallbacks.
--   - SQL callers (orphan_event_auto_backfill, server_side_pulls_*,
--     consolidate_orders_crons_our_orders_view, sg_seller_api_2026,
--     tournament_pull_by_category, tournament_event_backfill,
--     venue_specific_pulls, c1_stop_cron_on_inactive_events) all invoke
--     get_app_secret() inside SECURITY DEFINER functions owned by
--     postgres → inner `current_user` resolves to postgres (kept on
--     allowlist below).
--
-- Idempotent: REVOKE/GRANT are no-ops if already at target state, and
-- CREATE OR REPLACE preserves the function signature. Safe to apply-before-PR.

CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault
AS $function$
DECLARE v_value text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'get_app_secret: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;
  IF p_name NOT IN ('SEATDATA_API_KEY','TEVO_API_TOKEN','TEVO_SECRET','SEATGEEK_API_TOKEN') THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name
      USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value
    FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

REVOKE EXECUTE ON FUNCTION public.get_app_secret(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_app_secret(text) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;
