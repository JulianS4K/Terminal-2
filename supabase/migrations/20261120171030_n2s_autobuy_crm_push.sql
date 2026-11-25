-- Migration 20261120171030 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_crm_push,n2s_autobuy_crm_push(),n2s_autobuy_outcome_tick · reads:n2s_autobuy_exec,n2s_autobuy_result_json,n2s_items,n2s_gt_order_dryrun,net._http_response,get_app_secret · pre:20261113410000
--
-- A CONFIRMED N2S buy is pushed to the CRM webhook, with the order number we bought.
--
-- Operator 2026-11-20. Asked whether the buy order number goes out to the CRM through the
-- pipeline, it did not: the pipeline's push (n2s_cover_push_queue, 20260910350000) sends a
-- profitable cover BEFORE anything is bought, and the bought order number was only on the pull
-- feeds (GET /api/v1/subs/autobuys and /buys), which nothing has called since 2026-11-13.
-- Shown the choice: "Yes push it upon confirmation".
--
-- What goes out
--   when   a live n2s_autobuy_exec row reaches phase 'accepted': the sub we bought was confirmed
--          and our sale was accepted (the "N2S LIVE ACCEPTED" email goes out at the same time).
--          A row already accepted before this migration (exec 10, EVO 19464447 for GoTickets
--          order 8500756) goes out on the first run.
--   where  the same operator-configured endpoint as the cover push: vault N2S_COVER_WEBHOOK_URL,
--          with N2S_COVER_WEBHOOK_TOKEN as a Bearer token when set. Unset URL = nothing is sent.
--   what   the same JSON as one GET /api/v1/subs/autobuys item (n2s_autobuy_result_json:
--          buy_ref '<market>-<order number>', bought_on, bought_order_number, for_order {order
--          number, market, seats, sold total, sale state}, event, bought seats, totals, status
--          'went_through'), plus event 'n2s.autobuy_confirmed', exec_id, n2s_id, attempt,
--          pushed_at. The receiver dedupes on exec_id (or buy_ref): a retry repeats the message.
--   once   one row per exec in n2s_autobuy_crm_push. A send with no 2xx answer (an error status,
--          a timeout, or no answer 5 minutes on) is sent again, at most 3 sends in all, 5 minutes
--          apart; after that the row stays as it is and the pull feed is the catch-up path.
--   how    pg_net, from n2s_autobuy_outcome_tick (cron n2s_autobuy_outcome_1min), which calls
--          n2s_autobuy_crm_push() first thing, before its own email checks: no new cron job.
--          A failure there is raised as a WARNING and never stops the email.
--
-- RULE 2: the endpoint is ours, never a ticket marketplace; this sends our own data and creates
-- no order, hold, price or listing change anywhere. As in n2s_cover_push_queue, the URL comes
-- from the vault, so the static audit cannot see it: the function refuses to POST to any
-- listing-source host and raises instead. The list is the cover push's, kept identical.
--
-- VERIFY: SELECT exec_id, attempts, status_code, error_msg, fired_at, resolved_at,
--                payload->>'buy_ref' FROM n2s_autobuy_crm_push ORDER BY exec_id;
--         SELECT md5(pg_get_functiondef('public.n2s_autobuy_outcome_tick()'::regprocedure));
-- ROLLBACK: re-apply n2s_autobuy_outcome_tick() as 20261113400000 left it (md5
--           85fecc4eacd61c2aad1f9e72cf24df07: remove the three-line crm_push block);
--           DROP FUNCTION public.n2s_autobuy_crm_push(integer); DROP TABLE public.n2s_autobuy_crm_push;

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ── 1. the outbox ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.n2s_autobuy_crm_push (
  exec_id      bigint      PRIMARY KEY,           -- n2s_autobuy_exec.exec_id
  payload      jsonb       NOT NULL,              -- what the last send carried
  request_id   bigint,                            -- pg_net request of the last send
  attempts     integer     NOT NULL DEFAULT 1,
  fired_at     timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz,                       -- when pg_net's answer was read
  status_code  integer,                           -- the receiver's status; NULL = no answer / timed out
  error_msg    text
);
ALTER TABLE public.n2s_autobuy_crm_push ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_autobuy_crm_push FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.n2s_autobuy_crm_push IS
  'Outbox: one webhook message per confirmed N2S auto-buy (phase accepted) to N2S_COVER_WEBHOOK_URL, with the order number we bought. At most 3 sends. 20261120171030.';

-- ── 2. the push ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_autobuy_crm_push(p_max integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_url   text;
  v_token text;
  v_host  text;
  v_bad   text;
  e       public.n2s_autobuy_exec;
  v_try   integer;
  v_body  jsonb;
  v_req   bigint;
  v_sent  integer := 0;
  v_read  integer := 0;
BEGIN
  -- one run at a time: two overlapping runs would send the same row twice
  IF NOT pg_try_advisory_xact_lock(hashtext('n2s_autobuy_crm_push')) THEN
    RETURN jsonb_build_object('skipped', 'running');
  END IF;

  -- read what pg_net has answered for earlier sends
  WITH ans AS (
    UPDATE public.n2s_autobuy_crm_push p
       SET resolved_at = now(),
           status_code = r.status_code,
           error_msg   = CASE WHEN r.status_code BETWEEN 200 AND 299 THEN NULL
                              ELSE left(coalesce(r.error_msg, r.content), 500) END
      FROM net._http_response r
     WHERE r.id = p.request_id AND p.resolved_at IS NULL
    RETURNING 1)
  SELECT count(*) INTO v_read FROM ans;

  v_url := public.get_app_secret('N2S_COVER_WEBHOOK_URL');
  IF v_url IS NULL OR btrim(v_url) = '' THEN
    RETURN jsonb_build_object('configured', false, 'answers_read', v_read);
  END IF;
  v_token := public.get_app_secret('N2S_COVER_WEBHOOK_TOKEN');

  -- ⚠ RUNTIME RULE 2 GUARD, the same list as n2s_cover_push_queue: never POST to a listing source
  v_host := lower(coalesce(substring(v_url from '^[a-z]+://([^/?#]+)'), ''));
  FOREACH v_bad IN ARRAY ARRAY[
    'api.ticketevolution.com','api.sandbox.ticketevolution.com',
    'brokerdata.seatgeek.com','sellerdirect-api.seatgeek.com',
    'api.tickpick.com','brokers.vividseats.com','gotickets.com',
    'seatdata.io','ticketsdata.com','broadway.com','rest.bandsintown.com',
    'crm.s4kcs.com','axs.com','evenue.net']
  LOOP
    IF position(v_bad IN v_host) > 0 THEN
      RAISE EXCEPTION 'n2s_autobuy_crm_push: refusing to POST to upstream host % (RULE 2)', v_host;
    END IF;
  END LOOP;

  -- confirmed buys never sent, and sends with no 2xx answer, 5 minutes on, at most 3 in all
  FOR e IN
    SELECT x.*
      FROM public.n2s_autobuy_exec x
      LEFT JOIN public.n2s_autobuy_crm_push p ON p.exec_id = x.exec_id
     WHERE x.mode = 'live' AND x.phase = 'accepted' AND x.buy_order_id IS NOT NULL
       AND (p.exec_id IS NULL
            OR (p.attempts < 3 AND p.fired_at < now() - interval '5 minutes'
                AND coalesce(p.status_code NOT BETWEEN 200 AND 299, true)))
     ORDER BY x.exec_id
     LIMIT greatest(coalesce(p_max, 10), 1)
  LOOP
    v_try := coalesce((SELECT p.attempts FROM public.n2s_autobuy_crm_push p WHERE p.exec_id = e.exec_id), 0) + 1;
    v_body := public.n2s_autobuy_result_json(e)
              || jsonb_build_object('event', 'n2s.autobuy_confirmed', 'exec_id', e.exec_id,
                                    'n2s_id', e.n2s_id, 'attempt', v_try, 'pushed_at', now());
    SELECT net.http_post(
      url := v_url,
      body := v_body,
      headers := CASE WHEN coalesce(btrim(v_token), '') = ''
                      THEN jsonb_build_object('Content-Type', 'application/json')
                      ELSE jsonb_build_object('Content-Type', 'application/json',
                                              'Authorization', 'Bearer ' || v_token) END,
      timeout_milliseconds := 15000) INTO v_req;
    INSERT INTO public.n2s_autobuy_crm_push AS p (exec_id, payload, request_id, attempts, fired_at)
    VALUES (e.exec_id, v_body, v_req, v_try, now())
    ON CONFLICT (exec_id) DO UPDATE
      SET payload = EXCLUDED.payload, request_id = EXCLUDED.request_id, attempts = EXCLUDED.attempts,
          fired_at = EXCLUDED.fired_at, resolved_at = NULL, status_code = NULL, error_msg = NULL;
    v_sent := v_sent + 1;
  END LOOP;

  RETURN jsonb_build_object('configured', true, 'sent', v_sent, 'answers_read', v_read);
END
$function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_crm_push(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_crm_push(integer) TO service_role;

-- ── 3. the outcome tick runs it, every minute ──────────────────────────────
DO $do$
DECLARE d text; n int;
  v_old text := $r$BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;$r$;
  v_new text := $r$BEGIN
  -- 20261120171030: a confirmed buy goes to the CRM webhook; its failure never stops the email
  BEGIN PERFORM public.n2s_autobuy_crm_push();
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'CRM push failed: %', SQLERRM; END;
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;$r$;
BEGIN
  d := pg_get_functiondef('public.n2s_autobuy_outcome_tick()'::regprocedure);
  IF md5(d) <> '85fecc4eacd61c2aad1f9e72cf24df07' THEN
    RAISE EXCEPTION 'n2s_autobuy_outcome_tick drifted from 20261113400000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, v_old, ''))) / length(v_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_outcome_tick: % anchors (want 1) — re-derive this migration', n;
  END IF;
  EXECUTE replace(d, v_old, v_new);
END $do$;

COMMIT;
