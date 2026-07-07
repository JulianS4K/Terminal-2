-- ============================================================================
-- Migration 20260706113000 — get_app_secret: whitelist TWITTERAPI_IO_KEY
--
-- Lane:     xref+macro (A1 data plane — DB security surface)
-- Touches:  public.get_app_secret (W/function)
-- Pre-reqs: 20260527040000 (prior whitelist state), vault.TWITTERAPI_IO_KEY
--           (operator creates: SELECT vault.create_secret('<key>', 'TWITTERAPI_IO_KEY');)
--
-- Adds TWITTERAPI_IO_KEY to the get_app_secret allowlist so the X news-wire
-- queue (mig 20260706114500, x_news_queue) can pass the TwitterAPI.io key as
-- the X-API-Key header on its pg_net GETs. Until the operator creates the
-- vault secret, get_app_secret returns NULL and the queue no-ops.
--
-- Whitelist restatement verified against LIVE prod pg_proc 2026-07-06: prod
-- carries exactly the 9 names from 20260527040000 (no out-of-band additions),
-- so this CREATE OR REPLACE loses nothing. Full whitelist after this
-- migration (10 names):
--   SEATDATA_API_KEY, TEVO_API_TOKEN, TEVO_SECRET, SEATGEEK_API_TOKEN,
--   TICKPICK_API_TOKEN, VIVID_API_TOKEN, APPSCRIPT_INGEST_SECRET,
--   TICKETSDATA_USERNAME, TICKETSDATA_PASSWORD, TWITTERAPI_IO_KEY
-- ============================================================================

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
    'TICKETSDATA_PASSWORD',
    'TWITTERAPI_IO_KEY'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name
      USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value
    FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;
