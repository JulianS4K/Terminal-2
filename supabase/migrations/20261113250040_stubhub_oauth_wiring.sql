-- Migration 20261113250000 · level:data-collection · lane:A1 · writes:stubhub_api_config,stubhub_token_state,stubhub_oauth_state,vault.secrets(STUBHUB_ACCESS_TOKEN,STUBHUB_REFRESH_TOKEN),cron:stubhub_token_refresh_10min · reads:vault.decrypted_secrets(STUBHUB_CLIENT_ID,STUBHUB_CLIENT_SECRET) · pre:20261113240000
--
-- StubHub API — OAuth wiring for OUR seller account, READ-ONLY and SWITCHED OFF.
--
-- Operator 2026-11-13: "wire the api but keep turned off and read only till we get tokens".
-- StubHub (with Gametime) is a marketplace we only see through the S4K CRM; this wires a direct,
-- read-only path to our own StubHub sales + listings (stubhub_client.py) without turning it on.
--
-- HOW IT WORKS (developer.stubhub.com/docs/authentication, user-login flow):
--   1. An operator calls GET /api/admin/stubhub/connect (auth-gated) → stubhub_oauth_begin()
--      returns https://account.stubhub.com/authorize?…&scope=<read scopes>&state=<one-time>.
--   2. The StubHub account holder signs in ON STUBHUB'S PAGE and approves. We never see the password.
--   3. StubHub redirects to /api/stubhub/oauth/callback?code&state → stubhub_oauth_complete()
--      checks the one-time state and swaps the code for tokens (POST /oauth2/token, HTTP Basic
--      client_id:client_secret from Vault). Tokens go to Vault (STUBHUB_ACCESS_TOKEN,
--      STUBHUB_REFRESH_TOKEN); stubhub_token_state keeps only expiry/scope/status — no secret.
--   4. stubhub_token_refresh() (cron every 10 min) swaps the refresh token for a new pair once the
--      access token is within 15 minutes of expiry. StubHub refresh tokens are SINGLE-USE: the new
--      one is saved on every refresh, or the account has to be reconnected.
--
-- SWITCHED OFF: stubhub_api_config.enabled = false. Until an operator sets it true, begin/complete
-- raise and the refresh returns 'disabled' without any network call. The Python side is gated
-- separately by the Render env var STUBHUB_API_ENABLED=1. Both must be on.
--
-- READ-ONLY (RULE 2): the only POST anywhere is the OAuth token login on account.stubhub.com
-- (writes none of our data, same class as the TickPick token login; sanctioned in
-- scripts/check_readonly.py). Scopes are limited to read:* by a CHECK on the config row, by
-- stubhub_oauth_begin(), and stubhub_token_store_() refuses to keep a token that came back with
-- any write:* scope. The data client (stubhub_client.py) is GET-only.
--
-- TO TURN ON (operator): register the app with StubHub (redirect URI = the deployed
-- /api/stubhub/oauth/callback), put STUBHUB_CLIENT_ID + STUBHUB_CLIENT_SECRET in Vault, set
-- stubhub_api_config.redirect_uri and enabled = true, set STUBHUB_API_ENABLED=1 on Render, open
-- /api/admin/stubhub/connect, approve on StubHub. To read data from Python, also whitelist
-- STUBHUB_ACCESS_TOKEN in get_app_secret().
--
-- rollback: SELECT cron.unschedule('stubhub_token_refresh_10min');
--           DROP FUNCTION stubhub_token_refresh(boolean), stubhub_oauth_complete(text,text),
--                         stubhub_oauth_begin(text), stubhub_token_store_(jsonb);
--           DROP TABLE stubhub_oauth_state, stubhub_token_state, stubhub_api_config;

BEGIN;

CREATE TABLE IF NOT EXISTS public.stubhub_api_config (
  id            boolean PRIMARY KEY DEFAULT true CHECK (id),
  enabled       boolean NOT NULL DEFAULT false,
  env           text    NOT NULL DEFAULT 'production' CHECK (env IN ('production', 'sandbox')),
  scopes        text    NOT NULL DEFAULT 'read:sales read:sellerlistings read:events read:payment'
                CHECK (scopes ~ '^read:[a-z]+( read:[a-z]+)*$'),
  redirect_uri  text    CHECK (redirect_uri IS NULL OR redirect_uri ~ '^https://'),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.stubhub_api_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
COMMENT ON TABLE public.stubhub_api_config IS
  'StubHub API switch + OAuth settings (single row). enabled=false until the operator has '
  'app credentials and has connected the account. scopes must be read:* only. Mig 20261113250000.';

CREATE TABLE IF NOT EXISTS public.stubhub_token_state (
  id               boolean PRIMARY KEY DEFAULT true CHECK (id),
  connected_at     timestamptz,
  refreshed_at     timestamptz,
  expires_at       timestamptz,
  scope            text,
  last_attempt_at  timestamptz,
  last_http        integer,
  last_error       text,
  attempts         integer NOT NULL DEFAULT 0
);
INSERT INTO public.stubhub_token_state (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
COMMENT ON TABLE public.stubhub_token_state IS
  'StubHub OAuth token status (no secrets — the tokens live in Vault). Mig 20261113250000.';

CREATE TABLE IF NOT EXISTS public.stubhub_oauth_state (
  state       text PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text,
  used_at     timestamptz
);
COMMENT ON TABLE public.stubhub_oauth_state IS
  'One-time OAuth state values for the StubHub connect flow (15-minute lifetime). Mig 20261113250000.';

ALTER TABLE public.stubhub_api_config  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stubhub_token_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stubhub_oauth_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stubhub_api_config, public.stubhub_token_state, public.stubhub_oauth_state
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.stubhub_api_config, public.stubhub_token_state TO service_role;

-- Keep a token response: tokens to Vault, the rest to stubhub_token_state. Refuses write scopes.
CREATE OR REPLACE FUNCTION public.stubhub_token_store_(p_resp jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  tok text := p_resp ->> 'access_token';
  rtk text := p_resp ->> 'refresh_token';
  scp text := coalesce(p_resp ->> 'scope', '');
  ttl integer := coalesce(nullif(p_resp ->> 'expires_in', '')::integer, 3600);
  sid uuid;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'stubhub_token_store_: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  IF tok IS NULL OR length(tok) < 10 THEN
    RETURN 'no_access_token';
  END IF;
  IF scp ~ 'write:' THEN
    -- RULE 2: never keep a token that can write to StubHub.
    UPDATE public.stubhub_token_state SET last_attempt_at = now(), last_error = 'write_scope_refused' WHERE id;
    RETURN 'write_scope_refused';
  END IF;

  SELECT id INTO sid FROM vault.secrets WHERE name = 'STUBHUB_ACCESS_TOKEN';
  IF sid IS NULL THEN
    PERFORM vault.create_secret(tok, 'STUBHUB_ACCESS_TOKEN', 'StubHub API access token (stubhub_token_refresh)');
  ELSE
    PERFORM vault.update_secret(sid, tok);
  END IF;
  IF rtk IS NOT NULL AND length(rtk) >= 10 THEN
    sid := NULL;
    SELECT id INTO sid FROM vault.secrets WHERE name = 'STUBHUB_REFRESH_TOKEN';
    IF sid IS NULL THEN
      PERFORM vault.create_secret(rtk, 'STUBHUB_REFRESH_TOKEN', 'StubHub API refresh token — single use, rotated on every refresh');
    ELSE
      PERFORM vault.update_secret(sid, rtk);
    END IF;
  END IF;

  UPDATE public.stubhub_token_state
     SET refreshed_at = now(), expires_at = now() + make_interval(secs => ttl), scope = scp,
         last_attempt_at = now(), last_http = 200, last_error = NULL, attempts = attempts + 1
   WHERE id;
  RETURN 'stored';
END $function$;

-- Step 1: the URL that sends the StubHub account holder to StubHub's consent page.
CREATE OR REPLACE FUNCTION public.stubhub_oauth_begin(p_created_by text DEFAULT NULL)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  cfg   public.stubhub_api_config%ROWTYPE;
  cid   text;
  st    text := encode(extensions.gen_random_bytes(24), 'hex');
  host  text;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'stubhub_oauth_begin: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  SELECT * INTO cfg FROM public.stubhub_api_config WHERE id;
  IF NOT cfg.enabled THEN
    RAISE EXCEPTION 'StubHub API is switched off (stubhub_api_config.enabled = false)' USING ERRCODE = '55000';
  END IF;
  IF cfg.redirect_uri IS NULL THEN
    RAISE EXCEPTION 'stubhub_api_config.redirect_uri is not set' USING ERRCODE = '55000';
  END IF;
  SELECT decrypted_secret INTO cid FROM vault.decrypted_secrets WHERE name = 'STUBHUB_CLIENT_ID';
  IF cid IS NULL THEN
    RAISE EXCEPTION 'STUBHUB_CLIENT_ID is not in Vault' USING ERRCODE = '55000';
  END IF;

  DELETE FROM public.stubhub_oauth_state WHERE created_at < now() - interval '1 day';
  INSERT INTO public.stubhub_oauth_state (state, created_by) VALUES (st, left(p_created_by, 200));

  host := CASE cfg.env WHEN 'sandbox' THEN 'https://sandbox.account.stubhub.com' ELSE 'https://account.stubhub.com' END;
  RETURN host || '/authorize?client_id=' || extensions.urlencode(cid::varchar)
      || '&response_type=code'
      || '&redirect_uri=' || extensions.urlencode(cfg.redirect_uri::varchar)
      || '&scope=' || replace(cfg.scopes, ' ', '%20')
      || '&state=' || st;
END $function$;

-- Step 3: StubHub redirected back with ?code&state — swap the code for tokens.
CREATE OR REPLACE FUNCTION public.stubhub_oauth_complete(p_state text, p_code text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  cfg   public.stubhub_api_config%ROWTYPE;
  cid   text; csec text;
  n     integer;
  resp  extensions.http_response;
  j     jsonb;
  res   text;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'stubhub_oauth_complete: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  SELECT * INTO cfg FROM public.stubhub_api_config WHERE id;
  IF NOT cfg.enabled THEN
    RETURN 'disabled';
  END IF;
  -- One-time, 15-minute state: consumed here whatever happens next.
  UPDATE public.stubhub_oauth_state SET used_at = now()
   WHERE state = p_state AND used_at IS NULL AND created_at > now() - interval '15 minutes';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RETURN 'bad_state';
  END IF;
  IF coalesce(p_code, '') = '' OR length(p_code) > 2000 THEN
    RETURN 'no_code';
  END IF;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'STUBHUB_CLIENT_ID'),
         max(decrypted_secret) FILTER (WHERE name = 'STUBHUB_CLIENT_SECRET')
    INTO cid, csec FROM vault.decrypted_secrets;
  IF cid IS NULL OR csec IS NULL THEN
    RETURN 'no_client_credentials';
  END IF;

  PERFORM set_config('http.timeout_msec', '15000', true);
  -- OAuth token login. The response holds the tokens, so it is never logged or raised.
  BEGIN
    IF cfg.env = 'sandbox' THEN
      resp := extensions.http(('POST', 'https://sandbox.account.stubhub.com/oauth2/token',
                ARRAY[extensions.http_header('Authorization', 'Basic ' || replace(encode(convert_to(cid || ':' || csec, 'UTF8'), 'base64'), E'\n', ''))],
                'application/x-www-form-urlencoded',
                'grant_type=authorization_code&code=' || extensions.urlencode(p_code::varchar)
                || '&redirect_uri=' || extensions.urlencode(cfg.redirect_uri::varchar)
                || '&scope=' || replace(cfg.scopes, ' ', '%20'))::extensions.http_request);
    ELSE
      resp := extensions.http(('POST', 'https://account.stubhub.com/oauth2/token',
                ARRAY[extensions.http_header('Authorization', 'Basic ' || replace(encode(convert_to(cid || ':' || csec, 'UTF8'), 'base64'), E'\n', ''))],
                'application/x-www-form-urlencoded',
                'grant_type=authorization_code&code=' || extensions.urlencode(p_code::varchar)
                || '&redirect_uri=' || extensions.urlencode(cfg.redirect_uri::varchar)
                || '&scope=' || replace(cfg.scopes, ' ', '%20'))::extensions.http_request);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.stubhub_token_state SET last_attempt_at = now(), last_http = -1, last_error = 'request_failed',
           attempts = attempts + 1 WHERE id;
    RETURN 'request_failed';
  END;
  BEGIN
    j := resp.content::jsonb;
  EXCEPTION WHEN OTHERS THEN j := NULL;
  END;
  IF resp.status <> 200 OR j IS NULL THEN
    UPDATE public.stubhub_token_state
       SET last_attempt_at = now(), last_http = resp.status, attempts = attempts + 1,
           last_error = left(coalesce(j ->> 'error', 'token_exchange_failed'), 60)
     WHERE id;
    RETURN 'exchange_failed:' || resp.status;
  END IF;
  res := public.stubhub_token_store_(j);
  IF res = 'stored' THEN
    UPDATE public.stubhub_token_state SET connected_at = now() WHERE id;
    RETURN 'connected';
  END IF;
  RETURN res;
END $function$;

-- Step 4: keep the token fresh. No network call while switched off or not connected.
CREATE OR REPLACE FUNCTION public.stubhub_token_refresh(p_force boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  cfg   public.stubhub_api_config%ROWTYPE;
  st    public.stubhub_token_state%ROWTYPE;
  cid   text; csec text; rtk text;
  resp  extensions.http_response;
  j     jsonb;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'stubhub_token_refresh: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  SELECT * INTO cfg FROM public.stubhub_api_config WHERE id;
  IF NOT cfg.enabled THEN
    RETURN 'disabled';
  END IF;
  SELECT * INTO st FROM public.stubhub_token_state WHERE id FOR UPDATE;
  IF NOT p_force AND st.expires_at IS NOT NULL AND st.expires_at > now() + interval '15 minutes' THEN
    RETURN 'fresh';
  END IF;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'STUBHUB_CLIENT_ID'),
         max(decrypted_secret) FILTER (WHERE name = 'STUBHUB_CLIENT_SECRET'),
         max(decrypted_secret) FILTER (WHERE name = 'STUBHUB_REFRESH_TOKEN')
    INTO cid, csec, rtk FROM vault.decrypted_secrets;
  IF cid IS NULL OR csec IS NULL THEN
    RETURN 'no_client_credentials';
  END IF;
  IF rtk IS NULL THEN
    RETURN 'not_connected';
  END IF;

  PERFORM set_config('http.timeout_msec', '15000', true);
  BEGIN
    IF cfg.env = 'sandbox' THEN
      resp := extensions.http(('POST', 'https://sandbox.account.stubhub.com/oauth2/token',
                ARRAY[extensions.http_header('Authorization', 'Basic ' || replace(encode(convert_to(cid || ':' || csec, 'UTF8'), 'base64'), E'\n', ''))],
                'application/x-www-form-urlencoded',
                'grant_type=refresh_token&refresh_token=' || extensions.urlencode(rtk::varchar)
                || '&scope=' || replace(cfg.scopes, ' ', '%20'))::extensions.http_request);
    ELSE
      resp := extensions.http(('POST', 'https://account.stubhub.com/oauth2/token',
                ARRAY[extensions.http_header('Authorization', 'Basic ' || replace(encode(convert_to(cid || ':' || csec, 'UTF8'), 'base64'), E'\n', ''))],
                'application/x-www-form-urlencoded',
                'grant_type=refresh_token&refresh_token=' || extensions.urlencode(rtk::varchar)
                || '&scope=' || replace(cfg.scopes, ' ', '%20'))::extensions.http_request);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.stubhub_token_state SET last_attempt_at = now(), last_http = -1, last_error = 'request_failed',
           attempts = attempts + 1 WHERE id;
    RETURN 'request_failed';
  END;
  BEGIN
    j := resp.content::jsonb;
  EXCEPTION WHEN OTHERS THEN j := NULL;
  END;
  IF resp.status <> 200 OR j IS NULL THEN
    UPDATE public.stubhub_token_state
       SET last_attempt_at = now(), last_http = resp.status, attempts = attempts + 1,
           last_error = left(coalesce(j ->> 'error', 'refresh_failed'), 60)
     WHERE id;
    RETURN 'refresh_failed:' || resp.status;
  END IF;
  RETURN public.stubhub_token_store_(j);
END $function$;

REVOKE ALL ON FUNCTION public.stubhub_token_store_(jsonb)         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.stubhub_oauth_begin(text)           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.stubhub_oauth_complete(text, text)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.stubhub_token_refresh(boolean)      FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stubhub_oauth_begin(text)          TO service_role;
GRANT EXECUTE ON FUNCTION public.stubhub_oauth_complete(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.stubhub_token_refresh(boolean)     TO service_role;

-- Returns 'disabled' (no network call) until the operator switches it on.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stubhub_token_refresh_10min') THEN
    PERFORM cron.unschedule('stubhub_token_refresh_10min');
  END IF;
  PERFORM cron.schedule('stubhub_token_refresh_10min', '4-59/10 * * * *',
                        'SELECT public.stubhub_token_refresh(false);');
END
$cron$;

COMMIT;
