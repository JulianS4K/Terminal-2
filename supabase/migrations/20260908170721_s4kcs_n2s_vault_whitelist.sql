-- Migration 20260908170721 · level:security · lane:D0 · writes:none · reads:vault.decrypted_secrets · pre:20260901173000
-- Already applied to prod · via MCP 2026-09-08 (recorded there as version
-- 20260908171201 — apply_migration stamps its own timestamp; this file is the
-- idempotent codification, and a re-apply under either version is a no-op).
--
-- Whitelist the S4K CRM **N2S** API key in public.get_app_secret() under its
-- own name, 'crm.s4kcs.com/n2s', so s4kcs_client.py's n2s_* methods can
-- resolve it from Vault.
--
-- WHY A SECOND NAME, NOT A ROTATION OF 'crm.s4kcs.com'. The CRM issues
-- per-scope keys, and the two it has issued us are DISJOINT — verified live
-- against /api/v1/ping on 2026-09-08:
--     'crm.s4kcs.com'      → scopes ["marketplace:read"]  (exp 2027-08-28)
--     'crm.s4kcs.com/n2s'  → scopes ["n2s:read"]          (exp 2027-09-07)
-- So neither key can serve both surfaces. Overwriting the existing name with
-- the N2S key would 403 every /marketplace/orders pull and silently stop the
-- 10-minute s4kcs_orders ingest (mig 20260901180000, ~33k live rows); writing
-- it the other way round 403s every N2S read. Two scopes, two names — which
-- also keeps least privilege: a leak of one key does not expose the other.
--
-- SCOPE. Widens the allowlist by exactly one name and changes nothing else:
-- the caller check (service_role/postgres/supabase_admin), the search_path and
-- the body are otherwise byte-identical to the deployed function (verified via
-- pg_get_functiondef immediately before authoring — no drift since
-- 20260901173000). It grants no new caller any access; only code already
-- running as service_role can call it. Re-applying is a no-op.
--
-- SECRET VALUE. Not in this file and never should be (RULE: no literal secret
-- in SQL). The value is seeded into the Vault separately under operator
-- direction; this migration only opens the gate the name must pass through.
-- Both the client and the SQL ingest btrim() defensively — the sibling
-- 'crm.s4kcs.com' value was once pasted with a leading space, which fails as
-- an opaque 401.

CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE v_value text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'get_app_secret: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  IF p_name NOT IN (
    'SEATDATA_API_KEY','TEVO_API_TOKEN','TEVO_SECRET','SEATGEEK_API_TOKEN',
    'TICKPICK_API_TOKEN','VIVID_API_TOKEN','APPSCRIPT_INGEST_SECRET',
    'TICKETSDATA_USERNAME','TICKETSDATA_PASSWORD','TWITTERAPI_IO_KEY',
    'WA_GATEWAY_URL','WA_GATEWAY_KEY',
    -- S4K CRM marketplace API (crm.s4kcs.com) — read-only order book.
    'crm.s4kcs.com',
    -- S4K CRM N2S API (crm.s4kcs.com/api/v1/n2s) — read-only sub queue.
    -- Separate key: scope 'n2s:read' only, disjoint from the one above.
    'crm.s4kcs.com/n2s'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $$;

REVOKE ALL ON FUNCTION public.get_app_secret(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;
