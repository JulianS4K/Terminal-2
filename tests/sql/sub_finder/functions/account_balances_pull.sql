CREATE OR REPLACE FUNCTION public.account_balances_pull()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_run    bigint;
  v_status integer;
  v_body   text;
  v_err    text;
  v_evo    integer := 0;
  v_gt     integer := 0;
  v_evo_http integer;
  v_gt_http  integer;
  v_q      text := 'page=1&per_page=100';
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'account_balances_pull: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.account_balance_run DEFAULT VALUES RETURNING run_id INTO v_run;
  PERFORM set_config('http.timeout_msec', '20000', true);

  -- EVO office accounts (a signed GET)
  BEGIN
    SELECT r.status, r.content INTO v_status, v_body
      FROM extensions.http(('GET', 'https://api.ticketevolution.com/v9/accounts?' || v_q,
             ARRAY[extensions.http_header('X-Token', public.get_app_secret('TEVO_API_TOKEN')),
                   extensions.http_header('X-Signature',
                     public.tevo_sign_get('/v9/accounts', v_q, public.get_app_secret('TEVO_SECRET'))),
                   extensions.http_header('Accept', 'application/vnd.ticketevolution.api+json; version=9')],
             NULL, NULL)::extensions.http_request) r;
    v_evo_http := v_status;
    IF v_status = 200 THEN
      INSERT INTO public.account_balance (run_id, source, account_id, currency, balance, pending, pending_sent, spendable)
      SELECT v_run, 'evo', a->>'id', a->>'currency', (a->>'balance')::numeric, (a->>'pending_amount')::numeric,
             (a->>'pending_sent')::numeric, (a->>'spendable')::numeric
        FROM jsonb_array_elements(v_body::jsonb->'accounts') a
       WHERE a->>'id' IS NOT NULL
      ON CONFLICT DO NOTHING;
      GET DIAGNOSTICS v_evo = ROW_COUNT;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_err := left('evo: ' || SQLERRM, 300);
  END;

  -- GoTickets gift cards
  BEGIN
    SELECT r.status, r.content INTO v_status, v_body
      FROM extensions.http(('GET', 'https://gotickets.com/rest/pro/api/gift-cards',
             ARRAY[extensions.http_header('X-Broker-Api-Token', public._gotickets_pro_token()),
                   extensions.http_header('Accept', 'application/json')],
             NULL, NULL)::extensions.http_request) r;
    v_gt_http := v_status;
    IF v_status = 200 THEN
      INSERT INTO public.account_balance (run_id, source, account_id, label, currency, issued, balance, spendable)
      SELECT v_run, 'gotickets_gift_card', g->>'id', left(btrim(g->>'description'), 120), 'USD',
             (g->>'amount')::numeric, (g->>'amountRemaining')::numeric, (g->>'amountRemaining')::numeric
        FROM jsonb_array_elements(v_body::jsonb) g
       WHERE g->>'id' IS NOT NULL
      ON CONFLICT DO NOTHING;
      GET DIAGNOSTICS v_gt = ROW_COUNT;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_err := left(coalesce(v_err || '; ', '') || 'gotickets: ' || SQLERRM, 300);
  END;

  UPDATE public.account_balance_run
     SET evo_http = v_evo_http, evo_rows = v_evo, gt_http = v_gt_http, gt_rows = v_gt, error = v_err
   WHERE run_id = v_run;
  RETURN jsonb_build_object('run_id', v_run, 'evo_http', v_evo_http, 'evo_rows', v_evo,
                            'gt_http', v_gt_http, 'gt_rows', v_gt, 'error', v_err);
END
$function$

