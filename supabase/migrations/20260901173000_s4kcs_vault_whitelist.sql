-- Migration 20260901173000 · level:security · lane:D0 · writes:none · reads:vault.decrypted_secrets · pre:none
--
-- Whitelist the S4K CRM marketplace API key in public.get_app_secret() so the
-- server-side client (s4kcs_client.py) can resolve it from Vault.
--
-- WHY. get_app_secret() is the single SECURITY DEFINER gate through which
-- application code reads Vault; a name absent from its allowlist raises 42501.
-- The CRM key is stored under two names today — 'crm.s4kcs.com' (the
-- operator-designated name) and 'EVENUEDESK_API_KEY' (the earlier seed, same
-- value) — and neither is whitelisted, so s4kcs_client currently only resolves
-- its key from the S4KCS_API_KEY env var. Both names are added so a rotation of
-- either keeps working; the client tries them in that order.
--
-- SCOPE. This widens the allowlist by exactly two names and changes nothing
-- else: the caller check (service_role/postgres/supabase_admin) and the body
-- are otherwise byte-identical to the deployed function. It grants no new
-- caller any access — only code already running as service_role can call it.
--
-- NOTE. The value stored under 'crm.s4kcs.com' carries a LEADING SPACE, which
-- makes it invalid as an X-API-Key header verbatim. This migration deliberately
-- does NOT rewrite the secret (a vault write is an operator decision, and
-- rotating it is the cleaner fix); s4kcs_client strips defensively instead,
-- the same safety net TEVO_SECRET carries for its historical stray wrapping.

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
    'crm.s4kcs.com','EVENUEDESK_API_KEY'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $$;

REVOKE ALL ON FUNCTION public.get_app_secret(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;
