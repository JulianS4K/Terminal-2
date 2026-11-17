-- Migration 20261110020000 · level:data-collection · lane:A1 · writes:tickpick_token_state,tickpick_token_refresh,vault.secrets(TICKPICK_API_TOKEN),cron · reads:vault.decrypted_secrets · pre:20261110010000
--
-- TickPick API token: refresh it automatically from stored credentials.
--
-- Operator 2026-11-10: "going to use creds to pull tickpick token every few days" → automate
-- with stored creds. The vault's TICKPICK_API_TOKEN had been saved cut off at its first '.'
-- (74 chars, a JWT header only), so every TickPick call has returned 401 since 2026-05-13.
--
-- TickPick authenticates with an OAuth2 password grant (swagger securityDefinitions.oauth2,
-- flow "password"); the token endpoint is https://api.tickpick.com/1.0/token (a GET there
-- answers 400 unsupported_grant_type). tickpick_token_refresh() POSTs
--   grant_type=password&username=…&password=…   (application/x-www-form-urlencoded)
-- with TICKPICK_USERNAME / TICKPICK_PASSWORD from the vault, and stores the returned
-- access_token as TICKPICK_API_TOKEN (vault.update_secret, or create_secret if missing). Every
-- TickPick reader (tickpick_client.py via get_app_secret, any DB job) picks it up on its next call.
--
-- This login is the ONLY write to api.tickpick.com, and it writes none of our data and touches
-- no order, price or listing. scripts/check_readonly.py sanctions exactly this one URL for a
-- plpgsql POST (SANCTIONED_PLPGSQL_WRITE_URLS); any other POST near a TickPick host fails CI.
--
-- Cadence: cron tickpick_token_refresh_hourly runs every hour at :17. It logs in only when the
-- token has never been refreshed here, expires within 24 h, or a check GET with it returns 401;
-- otherwise it just makes that one check GET.
-- It no-ops until the operator adds TICKPICK_USERNAME and TICKPICK_PASSWORD in the vault.
-- Nothing secret is ever logged: tickpick_token_state keeps the HTTP status, expiry and an
-- error code, never the response body.
--
-- rollback: SELECT cron.unschedule('tickpick_token_refresh_hourly');
--           DROP FUNCTION tickpick_token_refresh(boolean); DROP TABLE tickpick_token_state;

CREATE TABLE IF NOT EXISTS public.tickpick_token_state (
  id              boolean     PRIMARY KEY DEFAULT true CHECK (id),
  refreshed_at    timestamptz,               -- last successful login
  expires_at      timestamptz,               -- refreshed_at + expires_in
  last_attempt_at timestamptz,
  last_http       integer,                   -- login status (200 = ok)
  last_error      text,                      -- e.g. invalid_grant, no_credentials (never a body)
  check_http      integer,                   -- status of the token check after login
  attempts        integer     NOT NULL DEFAULT 0
);
INSERT INTO public.tickpick_token_state (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.tickpick_token_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tickpick_token_state FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.tickpick_token_state TO service_role;

CREATE OR REPLACE FUNCTION public.tickpick_token_refresh(p_force boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  st     public.tickpick_token_state%ROWTYPE;
  usr    text; pwd text; cur text; sid uuid;
  resp   extensions.http_response;
  chk    integer;
  j      jsonb;
  tok    text;
  ttl    integer;
BEGIN
  SELECT * INTO st FROM public.tickpick_token_state WHERE id FOR UPDATE;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'TICKPICK_USERNAME'),
         max(decrypted_secret) FILTER (WHERE name = 'TICKPICK_PASSWORD'),
         max(decrypted_secret) FILTER (WHERE name = 'TICKPICK_API_TOKEN')
    INTO usr, pwd, cur FROM vault.decrypted_secrets;
  IF usr IS NULL OR pwd IS NULL THEN
    UPDATE public.tickpick_token_state SET last_attempt_at = now(), last_error = 'no_credentials' WHERE id;
    RETURN 'no_credentials';
  END IF;

  PERFORM set_config('http.timeout_msec', '15000', true);
  -- Is the current token still good? (GET — a read; also catches a token TickPick revoked early.)
  IF NOT p_force AND cur IS NOT NULL AND st.expires_at IS NOT NULL AND st.expires_at > now() + interval '24 hours' THEN
    BEGIN
      chk := (extensions.http(('GET', 'https://api.tickpick.com/1.0/orders?limit=1',
               ARRAY[extensions.http_header('Authorization', 'Bearer ' || cur)], NULL, NULL)::extensions.http_request)).status;
    EXCEPTION WHEN OTHERS THEN chk := -1;
    END;
    IF chk <> 401 THEN
      UPDATE public.tickpick_token_state SET check_http = chk WHERE id;
      RETURN 'fresh';
    END IF;
  END IF;

  -- Log in: OAuth2 password grant. The response body holds the token, so it is never stored or raised.
  BEGIN
    resp := extensions.http(('POST', 'https://api.tickpick.com/1.0/token', NULL, 'application/x-www-form-urlencoded',
              'grant_type=password&username=' || extensions.urlencode(usr::varchar)
              || '&password=' || extensions.urlencode(pwd::varchar))::extensions.http_request);
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.tickpick_token_state SET last_attempt_at = now(), last_http = -1, last_error = 'request_failed',
           attempts = attempts + 1 WHERE id;
    RETURN 'request_failed';
  END;
  BEGIN
    j := resp.content::jsonb;
  EXCEPTION WHEN OTHERS THEN j := NULL;
  END;
  tok := j ->> 'access_token';
  IF resp.status <> 200 OR tok IS NULL OR length(tok) < 20 THEN
    UPDATE public.tickpick_token_state
       SET last_attempt_at = now(), last_http = resp.status, attempts = attempts + 1,
           last_error = left(COALESCE(j ->> 'error', 'no_access_token'), 60)
     WHERE id;
    RETURN 'login_failed:' || resp.status;
  END IF;
  ttl := COALESCE(NULLIF(j ->> 'expires_in', '')::integer, 86400);

  SELECT id INTO sid FROM vault.secrets WHERE name = 'TICKPICK_API_TOKEN';
  IF sid IS NULL THEN
    PERFORM vault.create_secret(tok, 'TICKPICK_API_TOKEN', 'TickPick API token (auto-refreshed by tickpick_token_refresh)');
  ELSE
    PERFORM vault.update_secret(sid, tok);
  END IF;

  BEGIN
    chk := (extensions.http(('GET', 'https://api.tickpick.com/1.0/orders?limit=1',
             ARRAY[extensions.http_header('Authorization', 'Bearer ' || tok)], NULL, NULL)::extensions.http_request)).status;
  EXCEPTION WHEN OTHERS THEN chk := -1;
  END;
  UPDATE public.tickpick_token_state
     SET refreshed_at = now(), expires_at = now() + make_interval(secs => ttl), last_attempt_at = now(),
         last_http = 200, last_error = NULL, check_http = chk, attempts = attempts + 1
   WHERE id;
  RETURN 'refreshed:check=' || chk;
END $function$;

REVOKE ALL ON FUNCTION public.tickpick_token_refresh(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickpick_token_refresh(boolean) TO service_role;

SELECT cron.schedule('tickpick_token_refresh_hourly', '17 * * * *', $$SELECT public.tickpick_token_refresh();$$);
