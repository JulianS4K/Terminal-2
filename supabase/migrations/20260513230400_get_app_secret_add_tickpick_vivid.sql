-- Add TICKPICK_API_TOKEN + VIVID_API_TOKEN to the get_app_secret allowlist
-- so the new pg_cron ingest functions (tickpick_orders_queue, future
-- vivid_orders_queue) can read them from the vault.
--
-- Caught when the 2026-05-14 04:00 UTC tickpick_orders_queue_30min run
-- failed with "secret TICKPICK_API_TOKEN is not in the app whitelist".
-- The vault entries themselves were already present — only the allowlist
-- gate in get_app_secret was missing.

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
    'VIVID_API_TOKEN'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name
      USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value
    FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;
