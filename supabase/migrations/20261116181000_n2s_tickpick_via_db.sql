-- Migration 20261116181000 · level:secondary-sales · lane:D7 · writes:n2s_tickpick_confirm_log,n2s_tickpick_sale_state,n2s_tickpick_confirm · reads:n2s_autobuy_exec,n2s_items,vault.decrypted_secrets · pre:20261110070000
--
-- The N2S auto-buyer's TickPick calls go out from the DATABASE, not from the web service.
--
-- Why (2026-11-16): the first live attempt (exec 8, TickPick sale 1074350318) stopped with
-- sale_read_failed. The web service's read of the sale got a 4xx, while the database's
-- identical read, same Vault token, got 200 every minute (n2s_tickpick_byid_log). TickPick
-- allows API calls only from known addresses (docs/release-discipline.md R5); the database's
-- address is allowed, the web service's is not. Until this, no TickPick sale can be covered:
-- the sale read before the buy fails, and the confirm after it would fail the same way.
--
-- Operator 2026-11-16 ("Ok", to: log the status and TickPick's message on a failed read, and
-- move the TickPick sale read and the confirm into the database).
--
--   1. n2s_tickpick_sale_state(order_number): GET our sale's seller_status from TickPick.
--      Read-only. Returns {http, seller_status, order_status, error}; http -1 when the call
--      itself failed, 0 when the order number is not a plain number or there is no token.
--   2. n2s_tickpick_confirm_log: one row per N2S row whose sale we sent a confirm for, with
--      TickPick's answer. Its key makes the confirm once-only.
--   3. n2s_tickpick_confirm(exec_id, lease_token, order_number): confirm OUR OWN TickPick sale
--      for an N2S row, the same single write sale_accept_client.py has sent since 2026-11-10
--      (POST /1.0/orders/{n}/confirmation, empty body), now from here. It sends only when:
--        - the row is live, in phase 'sub_accepted' (our sub was bought and accepted by its
--          seller, and the worker has just re-checked its lease), sold on TickPick, with a
--          purchase id;
--        - the caller holds the row's lease (token matches, not expired);
--        - the sale's order number, read here from n2s_items, is a plain number and equals the
--          one the caller names.
--      Otherwise it returns {refused: <why>} and sends nothing. It sends at most once per row,
--      ever: the first answer is logged, and a repeat call (a dropped connection, retried)
--      returns that answer with {repeat: true} and sends nothing. A call that failed in flight
--      is logged as http -1, so a repeat is also "unknown", never a second send.
--      No reject, cancel, price or listing write exists here.
--
-- scripts/check_readonly.py: the confirm URL is built as one pinned expression,
-- SANCTIONED_PLPGSQL_WRITE_EXPRS; any other TickPick write near a POST still fails the build.
--
-- The HTTP timeout is 6 s: the API's statement timeout is 8 s (authenticator role), so the call
-- ends, and its answer is logged, before the statement would be cancelled.

-- ── 1. read our sale's state ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_tickpick_sale_state(p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  tok text;
  r   extensions.http_response;
  j   jsonb;
BEGIN
  IF p_order_number IS NULL OR p_order_number !~ '^[0-9]{1,18}$' THEN
    RETURN jsonb_build_object('http', 0, 'error', 'bad_order_number');
  END IF;
  SELECT decrypted_secret INTO tok FROM vault.decrypted_secrets WHERE name = 'TICKPICK_API_TOKEN';
  IF tok IS NULL THEN
    RETURN jsonb_build_object('http', 0, 'error', 'no_token');
  END IF;
  PERFORM set_config('http.timeout_msec', '6000', true);
  r := extensions.http(('GET', 'https://api.tickpick.com/1.0/orders/' || p_order_number,
         ARRAY[extensions.http_header('Authorization', 'Bearer ' || tok),
               extensions.http_header('Accept', 'application/json')], NULL, NULL)::extensions.http_request);
  BEGIN
    j := CASE WHEN r.content ~ '^\s*\{' THEN r.content::jsonb END;
  EXCEPTION WHEN OTHERS THEN
    j := NULL;
  END;
  RETURN jsonb_build_object(
    'http', r.status,
    'seller_status', j ->> 'seller_status',
    'order_status', j ->> 'order_status',
    'error', CASE WHEN r.status <> 200 THEN left(COALESCE(j ->> 'message', j ->> 'error', r.content, ''), 300) END);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('http', -1, 'error', left(SQLERRM, 300));
END $function$;

REVOKE ALL ON FUNCTION public.n2s_tickpick_sale_state(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_tickpick_sale_state(text) TO service_role;

-- ── 2. the once-only log ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.n2s_tickpick_confirm_log (
  exec_id      bigint      PRIMARY KEY REFERENCES public.n2s_autobuy_exec (exec_id),
  order_number text        NOT NULL,
  sent_at      timestamptz NOT NULL DEFAULT now(),
  http         integer     NOT NULL,      -- TickPick's status; -1 = the call failed in flight (unknown)
  body         text
);
ALTER TABLE public.n2s_tickpick_confirm_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_tickpick_confirm_log FROM PUBLIC, anon, authenticated;

-- ── 3. confirm our own sale, once, for a row the caller holds ──────────────
CREATE OR REPLACE FUNCTION public.n2s_tickpick_confirm(p_exec_id bigint, p_token uuid, p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e          public.n2s_autobuy_exec%ROWTYPE;
  l          public.n2s_tickpick_confirm_log%ROWTYPE;
  v_tp_order text;
  tok        text;
  r          extensions.http_response;
BEGIN
  -- the row lock serializes a repeat call behind the first, which then finds the logged answer
  SELECT * INTO e FROM public.n2s_autobuy_exec WHERE exec_id = p_exec_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('refused', 'no_row');
  END IF;
  SELECT * INTO l FROM public.n2s_tickpick_confirm_log WHERE exec_id = p_exec_id;
  IF FOUND THEN
    RETURN jsonb_build_object('http', l.http, 'body', l.body, 'repeat', true);
  END IF;
  IF e.mode IS DISTINCT FROM 'live' OR e.phase IS DISTINCT FROM 'sub_accepted'
     OR e.sell_market IS DISTINCT FROM 'tickpick' OR e.buy_order_id IS NULL
     OR p_token IS NULL OR e.lease_token IS DISTINCT FROM p_token
     OR e.lease_until IS NULL OR e.lease_until < now() THEN
    RETURN jsonb_build_object('refused', 'row_not_held');
  END IF;
  SELECT i.n2s_order_key INTO v_tp_order FROM public.n2s_items i WHERE i.n2s_id = e.n2s_id;
  IF v_tp_order IS NULL OR v_tp_order !~ '^[0-9]{1,18}$' OR v_tp_order IS DISTINCT FROM p_order_number THEN
    RETURN jsonb_build_object('refused', 'order_mismatch');
  END IF;
  SELECT decrypted_secret INTO tok FROM vault.decrypted_secrets WHERE name = 'TICKPICK_API_TOKEN';
  IF tok IS NULL THEN
    RETURN jsonb_build_object('refused', 'no_token');
  END IF;
  PERFORM set_config('http.timeout_msec', '6000', true);
  BEGIN
    r := extensions.http(('POST', 'https://api.tickpick.com/1.0/orders/' || v_tp_order || '/confirmation',
           ARRAY[extensions.http_header('Authorization', 'Bearer ' || tok),
                 extensions.http_header('Accept', 'application/json')],
           'application/json', '{}')::extensions.http_request);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.n2s_tickpick_confirm_log (exec_id, order_number, http, body)
    VALUES (p_exec_id, v_tp_order, -1, left(SQLERRM, 300));
    RETURN jsonb_build_object('http', -1, 'body', left(SQLERRM, 300));
  END;
  INSERT INTO public.n2s_tickpick_confirm_log (exec_id, order_number, http, body)
  VALUES (p_exec_id, v_tp_order, r.status, left(r.content, 500));
  RETURN jsonb_build_object('http', r.status, 'body', left(r.content, 500));
END $function$;

REVOKE ALL ON FUNCTION public.n2s_tickpick_confirm(bigint, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_tickpick_confirm(bigint, uuid, text) TO service_role;
