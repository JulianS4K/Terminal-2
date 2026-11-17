-- Migration 20261110010000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,get_app_secret · reads:vault.decrypted_secrets · pre:20261110000000
--
-- N2S live auto-buy: accept the covered sale on any market with a working token and a confirm
-- endpoint — EVO, GoTickets, SeatGeek, Vivid — not only EVO.
--
-- Operator 2026-11-10: "not just evo sales, any sales that have an active token and ability to
-- confirm order". The sub is still bought on EVO only (buy_sources '{tevo}'); what widens is the
-- market whose sale we accept. The accepts go through sale_accept_client.py, each pinned to one
-- (method, host, path) by SALE_ACCEPT_WRITES (check_readonly.py requires the literal):
--   GoTickets POST /rest/sales/{id}/confirm · SeatGeek PATCH /order (status=confirmed) ·
--   Vivid POST /webservices/v1/confirmOrder.
-- The worker refuses to buy (no_sale_accept_token) when the selling market's token is missing,
-- so it never buys a sub whose sale it cannot accept.
--
-- get_app_secret: GOTICKETS_ACCESS_ID / GOTICKETS_API_SECRET added to the whitelist (additive
-- only; the caller assert is unchanged). The web worker reads secrets through this RPC; the
-- database jobs already read them from vault directly.
--
-- rollback: UPDATE n2s_autobuy_config SET live_sell_markets = '{evo}';
--           (whitelist entries are harmless to keep; re-create get_app_secret without them to drop)

ALTER TABLE public.n2s_autobuy_config DROP CONSTRAINT IF EXISTS n2s_autobuy_config_live_sell_markets_check;
ALTER TABLE public.n2s_autobuy_config ADD CONSTRAINT n2s_autobuy_config_live_sell_markets_check
  CHECK (live_sell_markets <@ ARRAY['evo', 'gotickets', 'seatgeek', 'vivid']);
UPDATE public.n2s_autobuy_config
   SET live_sell_markets = ARRAY['evo', 'gotickets', 'seatgeek', 'vivid'], updated_at = now()
 WHERE id;

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
