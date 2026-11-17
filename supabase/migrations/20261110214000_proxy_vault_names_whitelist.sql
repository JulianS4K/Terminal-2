-- Migration 20261110214000 · level:infra · lane:A1 · writes:get_app_secret · reads:vault.decrypted_secrets · pre:20261110185500
--
-- Whitelist the proxy-provider secrets in get_app_secret() under the names the operator stored them
-- in Vault (operator 2026-11-10: "Whitelist names as stored"):
--   crawlproxies        crawlproxies User API key   → crawlproxies_client.py
--   OXY-Test-Username   Oxylabs Residential API     → oxylabs_client.py (Basic auth for POST /v2/login)
--   Oxy-Test-PW         Oxylabs Residential API     → oxylabs_client.py
--   oxylabs             44-char Oxylabs key (likely a Web API key; the Residential API cannot use it)
--
-- Additive only: the 20261110185500 list plus four names; caller assert, grants and body unchanged.
-- The secrets themselves are untouched.
--
-- rollback: re-create get_app_secret without these four names.
--
-- Already applied to prod · via MCP 2026-11-10 under operator direction ("Whitelist names as stored");
-- recorded in supabase_migrations.schema_migrations as 20261110213749 proxy_vault_names_whitelist.
-- Verified: all four names resolve; GOTICKETS_API_SECRET still resolves; EXECUTE service_role only.

CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
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
    'crm.s4kcs.com',
    'crm.s4kcs.com/n2s',
    'TICKETSDATA_N2S_USERNAME','TICKETSDATA_N2S_PASSWORD',
    'N2S_COVER_WEBHOOK_URL','N2S_COVER_WEBHOOK_TOKEN',
    'GOTICKETS_ACCESS_ID','GOTICKETS_API_SECRET',         -- 20261110010000: N2S live sale accept
    'CRAWLPROXIES_API_KEY',                               -- 20261110185500: crawlproxies User API
    'crawlproxies','oxylabs','OXY-Test-Username','Oxy-Test-PW' -- 20261110214000: names as the operator stored them
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

REVOKE ALL ON FUNCTION public.get_app_secret(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;
