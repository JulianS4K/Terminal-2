-- Migration 20261128120000 · level:secondary-sales · lane:a1 (the CRM order book reader) · writes:s4kcs_orders_direct_response(new),s4kcs_orders_direct_seq(new),s4kcs_orders_queue()(replaced: a direct read),s4kcs_orders_process()(patched in place: reads direct responses too),cron s4kcs_orders_queue_10min(statement_timeout 150 s) · reads:crm.s4kcs.com GET /api/v1/marketplace/orders (read-only)
--
-- THE ORDER BOOK IS READ DIRECTLY. Operator 2026-11-28, choosing option 2 of "ask the CRM team, or switch our
-- order-book reader to a direct read": "2".
--
-- WHY. Since 2026-11-27 08:37 UTC the CRM's GET /api/v1/marketplace/orders drops the connection to pg_net about 7 s
-- in ("Failure when receiving data from the peer", every run since), while one direct read (the http extension,
-- the way n2s_crm_fetch_direct already reads the CRM's Need-to-Sub feed) came back whole: 200, 8,800 orders. The
-- order book (s4kcs_orders.last_seen_at) has not moved since; GET /health shows order_book `down`.
--
-- WHAT. s4kcs_orders_queue() reads the endpoint itself (extensions.http, 120 s timeout), keeps the answer in
-- s4kcs_orders_direct_response under a negative request id (pg_net's ids are positive, so the two never meet), and
-- files the same s4kcs_orders_pending row as before. s4kcs_orders_process() reads its responses from pg_net's table
-- OR this one, so the processing, its partial-book warning, the retry of failed markets (s4kcs_orders_retry_failed,
-- unchanged: it still goes through pg_net per market) and the health check are untouched. A read that fails keeps
-- its error in the row and resolves as before (rows_persisted -1). Rows older than 2 days are deleted at each read.
-- The read holds a database connection while the CRM answers (up to 120 s, every 10 minutes), so the cron's
-- statement_timeout is raised to 150 s.
--
-- rollback: re-apply s4kcs_orders_queue() from 20260901180000 and replace in s4kcs_orders_process() the join
--           "JOIN (... s4kcs_orders_direct_response ...) h" with "JOIN net._http_response h"; the table can stay.

BEGIN;

CREATE SEQUENCE IF NOT EXISTS public.s4kcs_orders_direct_seq;
CREATE TABLE IF NOT EXISTS public.s4kcs_orders_direct_response (
  request_id  bigint PRIMARY KEY,          -- negative: -nextval('s4kcs_orders_direct_seq')
  status_code integer,
  content     text,
  error       text,
  ms          integer,
  created     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.s4kcs_orders_direct_response ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.s4kcs_orders_queue()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault', 'pg_temp'
AS $function$
DECLARE
  v_key    text := btrim(COALESCE(public.get_app_secret('crm.s4kcs.com'), ''));
  v_req_id bigint := -nextval('public.s4kcs_orders_direct_seq');
  v_t0     timestamptz := clock_timestamp();
  v_status integer;
  v_body   text;
  v_err    text;
BEGIN
  IF v_key = '' THEN
    RAISE NOTICE 'crm.s4kcs.com vault secret unset; skipping queue';
    RETURN 0;
  END IF;

  -- a direct read (mig 20261128120000): the CRM drops pg_net's connection to this endpoint since 2026-11-27 08:37
  BEGIN
    PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '120000');
    SELECT r.status, r.content INTO v_status, v_body
      FROM extensions.http((
        'GET', 'https://crm.s4kcs.com/api/v1/marketplace/orders',
        ARRAY[extensions.http_header('X-API-Key', v_key),
              extensions.http_header('Accept', 'application/json')],
        NULL, NULL)::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    v_err := left(SQLERRM, 300);
  END;
  PERFORM extensions.http_reset_curlopt();

  INSERT INTO public.s4kcs_orders_direct_response (request_id, status_code, content, error, ms)
  VALUES (v_req_id, v_status, v_body, v_err, (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int);
  INSERT INTO public.s4kcs_orders_pending (request_id, query_str)
  VALUES (v_req_id, 'all-markets');

  DELETE FROM public.s4kcs_orders_direct_response WHERE created < now() - interval '2 days';
  RETURN 1;
END;
$function$;
REVOKE ALL ON FUNCTION public.s4kcs_orders_queue() FROM PUBLIC, anon, authenticated;

-- the processor reads the direct responses too
DO $surgery$
DECLARE
  v_src text;
  v_old text := 'JOIN net._http_response h ON h.id = p.request_id';
  v_new text := 'JOIN (SELECT hr.id, hr.content, hr.status_code FROM net._http_response hr '
                || 'UNION ALL SELECT d.request_id, d.content, d.status_code FROM public.s4kcs_orders_direct_response d) h '
                || 'ON h.id = p.request_id  -- direct reads too (mig 20261128120000)';
BEGIN
  IF to_regprocedure('public.s4kcs_orders_process()') IS NULL THEN
    RAISE NOTICE 's4kcs_orders_process() not here: skipped';
    RETURN;
  END IF;
  SELECT pg_get_functiondef('public.s4kcs_orders_process()'::regprocedure) INTO v_src;
  IF position('mig 20261128120000' in v_src) > 0 THEN
    RAISE NOTICE 's4kcs_orders_process already reads direct responses';
    RETURN;
  END IF;
  IF (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 's4kcs_orders_process: the join to patch is not there exactly once';
  END IF;
  EXECUTE replace(v_src, v_old, v_new);
END $surgery$;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 's4kcs_orders_queue_10min') THEN
    PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 's4kcs_orders_queue_10min'),
                           command := 'SET statement_timeout = ''150s''; SELECT public.s4kcs_orders_queue();');
  END IF;
END $cron$;

COMMIT;
