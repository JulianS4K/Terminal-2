-- Migration 20260901173000 · level:security · lane:D0 · writes:none · reads:vault.decrypted_secrets · pre:none
--
-- Whitelist the S4K CRM marketplace API key in public.get_app_secret() so the
-- server-side client (s4kcs_client.py) can resolve it from Vault.
--
-- WHY. get_app_secret() is the single SECURITY DEFINER gate through which
-- application code reads Vault; a name absent from its allowlist raises 42501.
-- The CRM key lives under the single operator-designated name 'crm.s4kcs.com'.
-- (It was also seeded as 'EVENUEDESK_API_KEY'; that duplicate is deleted from
-- the Vault as part of this change, so only one name carries the key.)
--
-- SCOPE. This widens the allowlist by exactly one name and changes nothing
-- else: the caller check (service_role/postgres/supabase_admin) and the body
-- are otherwise byte-identical to the deployed function. It grants no new
-- caller any access — only code already running as service_role can call it.
--
-- NOTE. The value seeded under 'crm.s4kcs.com' carried a LEADING SPACE, which
-- makes it invalid as an X-API-Key header verbatim (the same class of paste
-- damage TEVO_SECRET carried). It was normalized in the Vault under operator
-- direction alongside this change. Both the client and the SQL ingest still
-- strip defensively — a re-paste can reintroduce it, and a whitespace-broken
-- key fails as an opaque 401.

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
    'crm.s4kcs.com'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $$;

REVOKE ALL ON FUNCTION public.get_app_secret(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;
