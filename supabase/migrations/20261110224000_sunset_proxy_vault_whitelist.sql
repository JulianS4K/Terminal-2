-- Migration 20261110224000 · level:infra · lane:A1 · writes:get_app_secret · reads:vault.decrypted_secrets · pre:20261110214000
--
-- Sunset the proxy integrations (operator 2026-11-10: "disregard all proxy related changes and
-- remove and sunset proxies"). The crawlproxies / Oxylabs clients were never merged; this rolls
-- get_app_secret() back to exactly the 20261110010000 whitelist, removing the five proxy names
-- added by 20261110185500 (CRAWLPROXIES_API_KEY) and 20261110214000 (crawlproxies, oxylabs,
-- OXY-Test-Username, Oxy-Test-PW). Caller assert, grants and body unchanged.
--
-- The vault secrets themselves are not touched by this migration.
--
-- rollback: re-apply 20261110214000.
--
-- Already applied to prod · via MCP 2026-11-10 under operator direction ("Apply whitelist rollback");
-- recorded in supabase_migrations.schema_migrations as 20261110224435 sunset_proxy_vault_whitelist.
-- Verified: no proxy names left; GOTICKETS_API_SECRET / TICKPICK_API_TOKEN still resolve;
-- SECURITY DEFINER, EXECUTE service_role only. Vault secrets left in place (operator choice).

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
    'GOTICKETS_ACCESS_ID','GOTICKETS_API_SECRET'          -- 20261110010000: N2S live sale accept
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

REVOKE ALL ON FUNCTION public.get_app_secret(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;
