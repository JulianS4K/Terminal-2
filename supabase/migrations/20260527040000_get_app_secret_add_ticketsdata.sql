-- 20260527040000_get_app_secret_add_ticketsdata.sql
--
-- Add TICKETSDATA_USERNAME + TICKETSDATA_PASSWORD to the get_app_secret allowlist.
-- Both vault secrets were created 2026-05-26 by the operator.
--
-- BLOCKER for the TicketsData integration: pg_cron functions call
-- get_app_secret('TICKETSDATA_USERNAME') and get_app_secret('TICKETSDATA_PASSWORD')
-- to retrieve credentials for the TicketsData API (/fetch, /events endpoints).
-- Without this change, those calls fail with "secret ... is not in the app whitelist".
--
-- NOTE: This migration also preserves APPSCRIPT_INGEST_SECRET, which was added to
-- prod directly (not via a migration file) and would otherwise be lost on next
-- CREATE OR REPLACE from the migration file 20260513230400. The drift is documented
-- in the plan and resolved here permanently.
--
-- Full prod whitelist after this migration (9 names):
--   SEATDATA_API_KEY, TEVO_API_TOKEN, TEVO_SECRET, SEATGEEK_API_TOKEN,
--   TICKPICK_API_TOKEN, VIVID_API_TOKEN, APPSCRIPT_INGEST_SECRET,
--   TICKETSDATA_USERNAME, TICKETSDATA_PASSWORD

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
    'APPSCRIPT_INGEST_SECRET',
    'TICKETSDATA_USERNAME',
    'TICKETSDATA_PASSWORD'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name
      USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value
    FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;
