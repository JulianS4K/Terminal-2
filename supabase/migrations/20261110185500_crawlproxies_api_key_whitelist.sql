-- Migration 20261110185500 · level:infra · lane:A1 · writes:get_app_secret · reads:vault.decrypted_secrets · pre:20261110010000
--
-- crawlproxies User API (crawlproxies_client.py): whitelist CRAWLPROXIES_API_KEY in
-- get_app_secret() so the client can resolve its `crawl_user_...` key from Vault
-- (arg → env CRAWLPROXIES_API_KEY → Vault, same as every other upstream client).
--
-- Additive only: the whitelist is the 20261110010000 list plus one name; the caller assert,
-- grants and body are unchanged. No secret is stored here — the operator creates it with
--   SELECT vault.create_secret('<crawl_user_...>', 'CRAWLPROXIES_API_KEY');
--
-- rollback: re-create get_app_secret without 'CRAWLPROXIES_API_KEY' (harmless to keep).
--
-- Already applied to prod · via MCP 2026-11-10 under operator direction ("apply the migration");
-- recorded in supabase_migrations.schema_migrations as 20261110213211 crawlproxies_api_key_whitelist.

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
    'CRAWLPROXIES_API_KEY'                                -- 20261110185500: crawlproxies User API
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

REVOKE ALL ON FUNCTION public.get_app_secret(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;
