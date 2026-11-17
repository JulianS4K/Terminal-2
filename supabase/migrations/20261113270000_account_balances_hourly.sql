-- Migration 20261113270000 · level:secondary-sales · lane:D0 · writes:account_balance_run,account_balance,account_balances_pull,sub_finder_balances,sub_finder_config,cron:account_balances_hourly · reads:vault.decrypted_secrets · pre:20261113160000
--
-- ACCOUNT BALANCES: read the EVO balances and the GoTickets gift cards every hour, and show
-- the latest to the CRM.
--
-- Operator 2026-11-13: "call the gotickets gift card, and the evo balances hourly and send
-- result to crm".
--
-- Two read-only GETs (RULE 2: reads; nothing is bought, held or changed):
--   EVO        GET https://api.ticketevolution.com/v9/accounts          one row per office
--              account: balance, pending_amount, pending_sent, spendable, currency.
--   GoTickets  GET https://gotickets.com/rest/pro/api/gift-cards        one row per gift card:
--              amount (issued) and amountRemaining.
-- Both were called once by hand on 2026-11-13 to confirm they answer and what they return.
-- GoTickets' /payment-methods is NOT read here (it answered [] and nothing asks for it).
--
--   account_balances_pull()   one run: both GETs, each on its own so one failing does not lose
--                             the other; a row in account_balance_run, and one row per account
--                             / card in account_balance. A gift card's emailAddress is not
--                             stored. Every reading is kept (about 500 small rows a day).
--   cron account_balances_hourly   minute 7 of every hour.
--   sub_finder_balances(key)  what the CRM reads through GET /api/v1/subs/balances: the newest
--                             good reading of each source, with totals and `stale` when a
--                             reading is over 2 hours old. Only for keys in
--                             sub_finder_config.balances_key_ids (empty = nobody).
-- We do not write to the CRM (its API has no write surface): "send" is this read.
--
-- rollback: SELECT cron.unschedule('account_balances_hourly');
--           DROP FUNCTION public.sub_finder_balances(bigint), public.account_balances_pull();
--           DROP TABLE public.account_balance, public.account_balance_run;
--           ALTER TABLE public.sub_finder_config DROP COLUMN balances_key_ids;

CREATE TABLE IF NOT EXISTS public.account_balance_run (
  run_id     bigserial PRIMARY KEY,
  taken_at   timestamptz NOT NULL DEFAULT now(),
  evo_http   integer,          -- HTTP status of the EVO read (NULL = the call itself failed)
  evo_rows   integer NOT NULL DEFAULT 0,
  gt_http    integer,
  gt_rows    integer NOT NULL DEFAULT 0,
  error      text
);

CREATE TABLE IF NOT EXISTS public.account_balance (
  run_id      bigint      NOT NULL REFERENCES public.account_balance_run(run_id) ON DELETE CASCADE,
  source      text        NOT NULL CHECK (source IN ('evo', 'gotickets_gift_card')),
  account_id  text        NOT NULL,          -- EVO office id / GoTickets gift card id
  label       text,                          -- gift card description
  currency    text,
  issued      numeric,                       -- gift card: amount issued
  balance     numeric,                       -- EVO: balance · gift card: amountRemaining
  pending     numeric,                       -- EVO: pending_amount
  pending_sent numeric,                      -- EVO: pending_sent
  spendable   numeric,                       -- EVO: spendable · gift card: amountRemaining
  PRIMARY KEY (run_id, source, account_id)
);

ALTER TABLE public.account_balance_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_balance     ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_balance_run, public.account_balance FROM PUBLIC, anon, authenticated;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS balances_key_ids bigint[] NOT NULL DEFAULT '{}';   -- keys that may read balances

CREATE OR REPLACE FUNCTION public.account_balances_pull()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, extensions, pg_temp
AS $$
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
$$;

-- What the CRM reads: the newest good reading of each source.
CREATE OR REPLACE FUNCTION public.sub_finder_balances(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c     public.sub_finder_config;
  v_evo bigint;
  v_gt  bigint;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) OR NOT (p_key_id = ANY (c.balances_key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not read balances');
  END IF;
  SELECT max(run_id) INTO v_evo FROM public.account_balance_run WHERE evo_http = 200 AND evo_rows > 0;
  SELECT max(run_id) INTO v_gt  FROM public.account_balance_run WHERE gt_http = 200;
  RETURN jsonb_build_object(
    'evo', (SELECT jsonb_build_object(
              'taken_at', r.taken_at, 'stale', r.taken_at < now() - interval '2 hours',
              'total_balance',   (SELECT coalesce(sum(b.balance), 0)   FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'evo'),
              'total_pending',   (SELECT coalesce(sum(b.pending), 0)   FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'evo'),
              'total_spendable', (SELECT coalesce(sum(b.spendable), 0) FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'evo'),
              'accounts', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                             'office_id', b.account_id, 'currency', b.currency, 'balance', b.balance,
                             'pending', b.pending, 'pending_sent', b.pending_sent, 'spendable', b.spendable)
                             ORDER BY b.spendable DESC NULLS LAST, b.account_id), '[]'::jsonb)
                           FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'evo'))
            FROM public.account_balance_run r WHERE r.run_id = v_evo),
    'gotickets_gift_cards', (SELECT jsonb_build_object(
              'taken_at', r.taken_at, 'stale', r.taken_at < now() - interval '2 hours',
              'card_count',        (SELECT count(*) FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card'),
              'cards_with_balance',(SELECT count(*) FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card' AND b.balance > 0),
              'total_issued',      (SELECT coalesce(sum(b.issued), 0)  FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card'),
              'total_remaining',   (SELECT coalesce(sum(b.balance), 0) FROM public.account_balance b WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card'),
              -- only cards that still hold money are listed; the spent ones are in the counts
              'cards', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                          'id', b.account_id, 'description', b.label, 'issued', b.issued, 'remaining', b.balance)
                          ORDER BY b.balance DESC, b.account_id), '[]'::jsonb)
                        FROM public.account_balance b
                        WHERE b.run_id = r.run_id AND b.source = 'gotickets_gift_card' AND b.balance > 0))
            FROM public.account_balance_run r WHERE r.run_id = v_gt),
    'generated_at', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
END
$$;

REVOKE ALL ON FUNCTION public.account_balances_pull(), public.sub_finder_balances(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.account_balances_pull(), public.sub_finder_balances(bigint) TO service_role;

DO $cron$
BEGIN
  IF to_regclass('cron.job') IS NULL THEN RETURN; END IF;                     -- no pg_cron here (local / CI)
  EXECUTE $q$
    SELECT cron.schedule('account_balances_hourly', '7 * * * *', 'SELECT public.account_balances_pull();')
     WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'account_balances_hourly')
  $q$;
END
$cron$;
