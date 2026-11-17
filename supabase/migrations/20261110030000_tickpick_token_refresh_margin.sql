-- Migration 20261110030000 · level:data-collection · lane:A1 · writes:tickpick_token_refresh · reads:vault.decrypted_secrets · pre:20261110020000
--
-- TickPick token refresh: fix the refresh margin and the token check.
--
-- First live run 2026-11-09 22:54 UTC: the login worked (873-char token, expires_in ≈ 24 h), and
-- the new token reads our orders (200). Two fixes:
--   1. TickPick tokens live exactly 24 h, so the "refresh when < 24 h left" rule was always true
--      and the hourly job would log in every hour. Now: refresh when < 3 h left (≈ every 21 h).
--   2. The check GET /1.0/orders?limit=1 timed out at 15 s (TickPick ignores limit and returns
--      the whole book). It now reads /1.0/orders?status=unfulfilled with a 30 s timeout. A check
--      that errors or times out (-1) is not a 401, so it does not trigger a login.
--
-- rollback: re-create tickpick_token_refresh(boolean) from 20261110020000.

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

  PERFORM set_config('http.timeout_msec', '30000', true);
  -- 20261110030000: refresh only inside the last 3 h of the token's 24 h life.
  IF NOT p_force AND cur IS NOT NULL AND st.expires_at IS NOT NULL AND st.expires_at > now() + interval '3 hours' THEN
    BEGIN
      chk := (extensions.http(('GET', 'https://api.tickpick.com/1.0/orders?status=unfulfilled',
               ARRAY[extensions.http_header('Authorization', 'Bearer ' || cur)], NULL, NULL)::extensions.http_request)).status;
    EXCEPTION WHEN OTHERS THEN chk := -1;
    END;
    IF chk <> 401 THEN
      UPDATE public.tickpick_token_state SET check_http = chk WHERE id;
      RETURN 'fresh:check=' || chk;
    END IF;
  END IF;

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
    chk := (extensions.http(('GET', 'https://api.tickpick.com/1.0/orders?status=unfulfilled',
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
