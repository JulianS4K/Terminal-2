-- Migration 20261116000000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_key,sub_finder_audit,sub_finder_key_gate,sub_finder_rebate_max,sub_finder_audit_log,sub_finder_idem,sub_finder_audit_read,sub_finder_access,sub_finder_need2buy,sub_finder_autobuy,sub_finder_buy,sub_finder_gt_offer_request,sub_finder_offer_json · reads:manual_sub_buy,manual_sub_buy_config,sub_finder_gt_offer,sub_finder_order,n2s_items · pre:20261114000000
--
-- WHAT THE CRM ASKED FOR BEFORE ITS FIRST REAL BUY (its note of 2026-11-16; operator the same
-- day: "do it all, build").
--
--   1. Two keys for one account (sub_finder_key). A key listed there acts for `account_id`: the
--      key id every job, order, buy and offer is filed under, and the one named in
--      sub_finder_config's key lists. A listed key always reads; it buys only with can_buy and
--      offers only with can_offer. So the CRM syncs with a key that cannot spend, and confirms
--      a buy with another. Each key keeps its own rate and daily quota (mcp_api_keys), so
--      reading can never use up the calls a buy needs. A key with no row here acts for itself,
--      as before.
--   2. Addresses (sub_finder_key.allowed_ips). When set, every call with that key must come
--      from one of them. sub_finder_config.write_requires_ip (false as shipped): a buy, an
--      offer or a settings change is refused for any key with no address registered.
--      routers/subs_api.py does the check, on the address our own edge proxy reports.
--   3. Limits on what a CRM key can spend (all NULL as shipped = no new limit):
--        crm_buy_per_order_cap_usd, crm_buy_daily_cap_usd   on buys a CRM key asks for, checked
--                                                           when it asks (sub_finder_buy); the
--                                                           buyer's own ceilings still apply
--        gt_offer_rebate_max_pct                            the most a rebate may be, as a
--                                                           percentage of the sale total
--      GET /ping names them (`limits`).
--   4. The label is `status` = `need2buy`, exactly (sub_finder_need2buy). The loose spellings
--      and the two other fields no longer count. No item in production matched them.
--   5. An order whose details the caller sent (order_source 'request') is never bought
--      automatically: auto_buy_note 'order_described_by_caller'.
--   6. Every buy, offer and loss-limit change asked through the API is written to
--      sub_finder_audit with the address it came from, refusals included
--      (GET /api/v1/subs/audit). The same rows make a repeated call safe: a buy or offer sent
--      again with the same Idempotency-Key gets the first answer back (sub_finder_idem).
--
-- Nothing here calls a market. Functions of ours are shipped whole (MIGRATION_CONVENTIONS 6a).
-- Production's sub_finder_buy differed from the repository's copy in two comments only, and
-- its sub_finder_gt_offer_request in the argument defaults only (checked line by line).
--
-- rollback: UPDATE public.sub_finder_config SET write_requires_ip = false, crm_buy_per_order_cap_usd = NULL,
--             crm_buy_daily_cap_usd = NULL, gt_offer_rebate_max_pct = NULL WHERE id = true;
--           TRUNCATE public.sub_finder_key;   -- every key acts for itself again
--           (the label rule and the request-order rule: re-apply the definitions in 20261113160000 / 20261113320000.)

-- ── 1. settings ────────────────────────────────────────────────────────────
ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS write_requires_ip         boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS crm_buy_per_order_cap_usd numeric CHECK (crm_buy_per_order_cap_usd IS NULL OR crm_buy_per_order_cap_usd >= 0),
  ADD COLUMN IF NOT EXISTS crm_buy_daily_cap_usd     numeric CHECK (crm_buy_daily_cap_usd IS NULL OR crm_buy_daily_cap_usd >= 0),
  ADD COLUMN IF NOT EXISTS gt_offer_rebate_max_pct   numeric CHECK (gt_offer_rebate_max_pct IS NULL OR gt_offer_rebate_max_pct BETWEEN 0 AND 100);

-- ── 2. keys of an account ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sub_finder_key (
  key_id      bigint PRIMARY KEY,                  -- mcp_api_keys.id: the credential
  account_id  bigint NOT NULL,                     -- the key id its jobs are filed under
  can_buy     boolean NOT NULL DEFAULT false,
  can_offer   boolean NOT NULL DEFAULT false,
  allowed_ips inet[],                              -- NULL or empty: any address
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sub_finder_key ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_key FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.sub_finder_key IS
  'Sub finder API: a key listed here acts for account_id (the key id jobs are filed under). It always reads; it buys with can_buy, offers with can_offer; with allowed_ips set it is accepted only from those addresses. A key not listed acts for itself. 20261116000000.';

-- What routers/subs_api.py needs to know about a key before it lets a call through.
CREATE OR REPLACE FUNCTION public.sub_finder_key_gate(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'account_id', coalesce(k.account_id, p_key_id),
    'listed', k.key_id IS NOT NULL,
    'buy', coalesce(k.can_buy, true), 'offer', coalesce(k.can_offer, true),
    'allowed_ips', coalesce((SELECT jsonb_agg(host(a) || CASE WHEN masklen(a) < (CASE family(a) WHEN 4 THEN 32 ELSE 128 END)
                                                              THEN '/' || masklen(a) ELSE '' END)
                               FROM unnest(k.allowed_ips) a), '[]'::jsonb),
    'write_requires_ip', c.write_requires_ip)
  FROM public.sub_finder_config c LEFT JOIN public.sub_finder_key k ON k.key_id = p_key_id;
$function$;

-- The most a rebate on a sale of this total may be. No ceiling set: the sale total, as before.
CREATE OR REPLACE FUNCTION public.sub_finder_rebate_max(p_sale_total numeric)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN c.gt_offer_rebate_max_pct IS NULL THEN p_sale_total
              ELSE round(p_sale_total * c.gt_offer_rebate_max_pct / 100.0, 2) END
    FROM public.sub_finder_config c;
$function$;

-- ── 3. the record of every buy, offer and settings change asked through the API ──
CREATE TABLE IF NOT EXISTS public.sub_finder_audit (
  audit_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at           timestamptz NOT NULL DEFAULT now(),
  account_id   bigint NOT NULL,
  key_id       bigint NOT NULL,                    -- the key that called
  key_label    text,
  action       text NOT NULL CHECK (action IN ('buy', 'offer', 'settings')),
  order_number text,
  listing_id   text,
  market       text,
  amount_usd   numeric,                            -- a buy: tickets at the price asked; an offer: the sub's total
  rebate_usd   numeric,
  source_ip    text,
  requested_by text,
  idem_key     text,
  http_status  integer NOT NULL,
  outcome      text NOT NULL,                      -- 'requested', 'saved', or the refusal's code
  buy_id       bigint,
  offer_id     bigint,
  response     jsonb                               -- the answer sent, kept to repeat it for the same Idempotency-Key
);
CREATE INDEX IF NOT EXISTS sub_finder_audit_account_at ON public.sub_finder_audit (account_id, at DESC, audit_id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS sub_finder_audit_one_per_idem ON public.sub_finder_audit (account_id, idem_key)
  WHERE idem_key IS NOT NULL AND http_status = 202;
ALTER TABLE public.sub_finder_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_audit FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.sub_finder_audit IS
  'Sub finder API: one row per buy, offer or loss-limit change asked through /api/v1/subs, refusals included, with the calling key and the address it came from. An accepted call with an Idempotency-Key is answered from here when it is sent again. 20261116000000.';

CREATE OR REPLACE FUNCTION public.sub_finder_audit_log(
  p_account_id bigint, p_key_id bigint, p_key_label text, p_action text, p_order_number text,
  p_listing_id text, p_source_ip text, p_requested_by text, p_idem_key text,
  p_http_status integer, p_response jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ok    boolean := p_http_status BETWEEN 200 AND 299;
  v_buy   bigint := CASE WHEN v_ok THEN nullif(p_response->>'buy_id', '')::bigint END;
  v_offer bigint := CASE WHEN v_ok THEN nullif(p_response->>'offer_id', '')::bigint END;
BEGIN
  INSERT INTO public.sub_finder_audit
    (account_id, key_id, key_label, action, order_number, listing_id, market, amount_usd, rebate_usd,
     source_ip, requested_by, idem_key, http_status, outcome, buy_id, offer_id, response)
  SELECT p_account_id, p_key_id, p_key_label, p_action, p_order_number, p_listing_id,
         coalesce(b.market, g.market, p_response->>'market'),
         coalesce(round(b.max_price_ea * b.qty, 2), g.sub_total),
         g.rebate_amount,
         p_source_ip, nullif(btrim(p_requested_by), ''), nullif(btrim(p_idem_key), ''), p_http_status,
         coalesce(p_response->>'error', p_response->>'state', CASE WHEN v_ok THEN 'saved' ELSE 'refused' END),
         v_buy, v_offer, CASE WHEN v_ok THEN p_response END
    FROM (SELECT 1) one
    LEFT JOIN public.manual_sub_buy b ON b.buy_id = v_buy
    LEFT JOIN public.sub_finder_gt_offer g ON g.offer_id = v_offer
  ON CONFLICT DO NOTHING;      -- a second accepted call under one Idempotency-Key: the first row stands
END
$function$;

-- The accepted call already made under this Idempotency-Key, or NULL.
CREATE OR REPLACE FUNCTION public.sub_finder_idem(p_account_id bigint, p_idem_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object('action', a.action, 'order_number', a.order_number, 'listing_id', a.listing_id,
                            'response', a.response)
    FROM public.sub_finder_audit a
   WHERE a.account_id = p_account_id AND a.idem_key = p_idem_key AND a.http_status = 202;
$function$;

-- GET /api/v1/subs/audit: the account's rows, newest first.
CREATE OR REPLACE FUNCTION public.sub_finder_audit_read(p_key_id bigint, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not read the audit log');
  END IF;
  RETURN (
    WITH f AS (
      SELECT * FROM public.sub_finder_audit a
       WHERE a.account_id = p_key_id AND (p_since IS NULL OR a.at >= p_since)
    ), page AS (
      SELECT * FROM f ORDER BY at DESC, audit_id DESC LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off,
      'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'at', to_char(p.at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                         'action', p.action, 'order_number', p.order_number, 'listing_id', p.listing_id,
                         'market', p.market, 'amount_usd', p.amount_usd, 'rebate_usd', p.rebate_usd,
                         'source_ip', p.source_ip, 'key_label', p.key_label, 'requested_by', p.requested_by,
                         'idempotency_key', p.idem_key, 'http_status', p.http_status, 'outcome', p.outcome,
                         'buy_id', p.buy_id, 'offer_id', p.offer_id)
                         ORDER BY p.at DESC, p.audit_id DESC), '[]'::jsonb) FROM page p),
      'generated_at', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$function$;

-- ── 4. our own functions, whole ────────────────────────────────────────────

-- ── the limits a key is held to, in its access answer ──
CREATE OR REPLACE FUNCTION public.sub_finder_access(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'enabled', c.enabled,
    'find', c.enabled AND p_key_id = ANY (c.key_ids),
    'buy',  c.enabled AND c.buy_enabled AND p_key_id = ANY (c.key_ids) AND p_key_id = ANY (c.buy_key_ids),
    'offer', c.enabled AND c.gt_offer_enabled AND p_key_id = ANY (c.key_ids) AND p_key_id = ANY (c.gt_offer_key_ids),
    'max_orders_per_job', c.max_orders_per_job, 'ticketsdata_fallback', c.td_enabled,
    -- 20261116000000: what a buy this key asks for is held to (the lower of the CRM's own cap and
    -- the buyer's), and the most a rebate may be. NULL = no such limit.
    'limits', jsonb_build_object(
      'buy_per_order_usd', least(c.crm_buy_per_order_cap_usd, m.per_order_cap_usd),
      'buy_per_day_usd', least(c.crm_buy_daily_cap_usd, m.daily_cap_usd),
      'rebate_max_pct', c.gt_offer_rebate_max_pct))
  FROM public.sub_finder_config c LEFT JOIN public.manual_sub_buy_config m ON true;
$function$;

-- ── the label: one exact value in one field ──
CREATE OR REPLACE FUNCTION public.sub_finder_need2buy(p_status text, p_status_label text, p_raw jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- 20261116000000 (the CRM's request): `status` equal to `need2buy`, exactly. No other field
  -- and no other spelling starts a lookup that may buy. The other two arguments are kept so
  -- callers do not change; they are not read.
  SELECT coalesce(p_status = 'need2buy', false);
$function$;

-- ── an order the caller described is never bought automatically ──
CREATE OR REPLACE FUNCTION public.sub_finder_autobuy(p_job_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config;
  j       public.sub_finder_job;
  o       public.sub_finder_order;
  cv      jsonb;
  v_note  text;
  v_buy   bigint;
  v_spent numeric;
  v_n     integer := 0;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_loss  numeric;                  -- the loss this order may be bought at, % of the sale; NULL = profit only
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF c.auto_buy_enabled THEN
    PERFORM pg_advisory_xact_lock(hashtext('sub_finder_autobuy'));   -- one cap check + request at a time
  END IF;
  SELECT * INTO j FROM public.sub_finder_job WHERE job_id = p_job_id;
  FOR o IN SELECT * FROM public.sub_finder_order
            WHERE job_id = p_job_id AND watching AND buy_id IS NULL AND state = 'cover' ORDER BY idx
  LOOP
    v_buy := NULL;
    -- 20261113320000: a loss is allowed only on a need2buy order, up to the CRM's limit for the
    -- marketplace it sold on (5% unless set); every other order is bought at a profit only
    v_loss := public.sub_finder_max_loss_pct(o.site, o.via_need2buy OR public.sub_finder_order_is_need2buy(o.order_number));
    -- the best one-to-one this may take: a profit, or (need2buy orders) breakeven or a gate 2 loss inside the limit;
    -- our own feed, exact quantity, clear view. Covers are ordered gate first, then cheapest.
    SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
     WHERE public.sub_finder_cover_buyable(o.order_number, x) AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x, v_loss)
       AND (x->>'spare')::int = 0 AND x->>'view' IS DISTINCT FROM 'obstructed'
       AND jsonb_array_length(public.sub_finder_cover_flags(x)) = 0     -- a flagged cover waits for the CRM
       AND ((x->>'gate')::int = 2      -- a gate 2 cover is already inside the loss limit (sub_finder_autobuy_gate)
            OR (x->>'profit')::numeric >= (x->>'total')::numeric * c.auto_buy_min_profit_pct / 100.0)
     ORDER BY n LIMIT 1;
    v_note := CASE
      WHEN NOT c.auto_buy_enabled THEN 'auto_buy_off'
      WHEN cv IS NOT NULL THEN NULL
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x, v_loss))
        THEN 'no_evo_one_to_one'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0)
        THEN 'needs_spare_ticket'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0
                         AND x->>'view' IS DISTINCT FROM 'obstructed')
        THEN 'obstructed_view'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0
                         AND x->>'view' IS DISTINCT FROM 'obstructed'
                         AND jsonb_array_length(public.sub_finder_cover_flags(x)) = 0)
        THEN 'needs_crm_confirm'
      ELSE 'profit_too_thin' END;
    -- 20261116000000: an order whose details the caller sent (order_source 'request') is never
    -- bought automatically, even if our own books later show the same seats and price
    IF v_note IS NULL AND o.order_source = 'request' THEN
      v_note := 'order_described_by_caller';
    END IF;
    IF v_note IS NULL AND (
         EXISTS (SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = o.order_number OR n.n2s_order_key = o.order_number)
                   AND NOT (n.item_source IS DISTINCT FROM 'gmail'
                            AND public.sub_finder_need2buy(n.status, n.status_label, n.raw)))
         OR EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = o.order_number)) THEN
      v_note := 'n2s_order';                           -- anything in the N2S book is never bought here
    END IF;
    IF v_note IS NULL AND EXISTS (
         SELECT 1 FROM public.manual_sub_buy b
          WHERE b.sale_order_number = o.order_number
            AND b.state IN ('requested', 'buying', 'bought', 'unknown')) THEN
      v_note := 'already_bought_for_this_sale';        -- whatever site name the other request used
    END IF;
    IF v_note IS NULL THEN
      -- the purchase is decided on OUR copy of the order, not on what the caller sent
      -- (the marketplace's own order feed, or our mirror of the CRM marketplace book; never N2S's)
      IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'marketplace'], true) THEN
        v_note := CASE WHEN (SELECT count(DISTINCT public.sub_finder_site_norm(l.site))
                               FROM public.sub_finder_lookup(o.order_number) l) = 1
                        AND EXISTS (SELECT 1 FROM public.sub_finder_lookup(o.order_number) l WHERE l.book <> 'n2s')
                       THEN 'differs_from_our_books' ELSE 'not_in_our_books' END;
      -- the sale must still be live on its marketplace
      ELSIF public.sub_finder_order_closed(o.order_number, o.site) IS NOT NULL THEN
        v_note := 'order_closed';
      END IF;
    END IF;
    IF v_note IS NULL THEN
      SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
        FROM public.manual_sub_buy b
       WHERE b.requested_by LIKE 'sub finder auto%' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
         AND (b.created_at AT TIME ZONE 'America/New_York')::date = v_today;
      IF v_spent + (cv->>'total')::numeric > c.auto_buy_daily_cap_usd THEN v_note := 'over_daily_cap'; END IF;
    END IF;
    IF v_note IS NULL THEN
      BEGIN
        v_buy := public.manual_sub_buy_request_market(cv->>'market',
          coalesce(o.site, 'CRM'), o.order_number, o.tevo_event_id, (cv->>'listing_id')::bigint,
          (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, o.sold_ea, o.event_name,
          'sub finder auto (key ' || coalesce(j.key_label, o.key_id::text) || ')',
          'auto: gate ' || (cv->>'gate') || ', sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
            || '; sub ' || (cv->>'section') || ' row ' || (cv->>'row') || ' x' || (cv->>'buy_qty')
            || ', quoted profit ' || (cv->>'profit'));
        v_n := v_n + 1;
      EXCEPTION WHEN unique_violation THEN
        v_note := 'already_bought_for_this_sale';
      END;
    END IF;
    UPDATE public.sub_finder_order
       SET buy_id = coalesce(v_buy, buy_id),
           action = CASE WHEN v_buy IS NOT NULL THEN 'auto_bought' ELSE action END,
           auto_buy_note = v_note,
           updated_at = CASE WHEN v_buy IS NOT NULL OR auto_buy_note IS DISTINCT FROM v_note THEN now()
                             ELSE updated_at END
     WHERE job_id = o.job_id AND idx = o.idx;
  END LOOP;
  RETURN v_n;
END
$function$;

-- ── caps on the buys a CRM key asks for ──
CREATE OR REPLACE FUNCTION public.sub_finder_buy(p_key_id bigint, p_key_label text, p_job_id uuid, p_order_number text, p_listing_id text, p_requested_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  o     public.sub_finder_order;
  cv    jsonb;
  v_buy bigint;
  v_n   integer;
  c     public.sub_finder_config;
  v_spent numeric;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'buy')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'buying is not enabled for this key');
  END IF;
  SELECT count(*) INTO v_n FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number;
  IF v_n = 0 THEN RETURN jsonb_build_object('error', 'not_found', 'detail', 'no such order in this job'); END IF;
  IF v_n > 1 THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this order number appears more than once in the job');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number FOR UPDATE;
  IF o.buy_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id AND b.state = 'stopped') THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy was already requested for this order',
                              'buy_id', o.buy_id);
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) x
   WHERE public.sub_finder_market_buyable(x->>'market') AND x->>'listing_id' = p_listing_id
   ORDER BY (x->>'market' = 'evo') DESC LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', 'that listing is not a cover we can buy that this job quoted for this order');
  END IF;
  -- 20261116000000: the caps on buys a CRM key asks for (NULL = none; the buyer's own ceilings
  -- still apply afterwards). Per order: this buy's quoted total. Per New York day: with every
  -- other buy a CRM key asked for today that was not stopped or failed.
  SELECT * INTO c FROM public.sub_finder_config;
  IF (cv->>'total')::numeric > c.crm_buy_per_order_cap_usd THEN
    RETURN jsonb_build_object('error', 'forbidden',
      'detail', 'this buy is over the limit for one order',
      'limit', 'per_order', 'limit_usd', c.crm_buy_per_order_cap_usd, 'this_buy_usd', (cv->>'total')::numeric);
  END IF;
  IF c.crm_buy_daily_cap_usd IS NOT NULL THEN
    SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
      FROM public.manual_sub_buy b
     WHERE b.requested_by LIKE 'crm api key %' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
       AND (b.created_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date;
    IF v_spent + (cv->>'total')::numeric > c.crm_buy_daily_cap_usd THEN
      RETURN jsonb_build_object('error', 'forbidden',
        'detail', 'this buy would take today''s buys over the daily limit',
        'limit', 'per_day', 'limit_usd', c.crm_buy_daily_cap_usd, 'this_buy_usd', (cv->>'total')::numeric,
        'spent_today_usd', v_spent);
    END IF;
  END IF;
  -- The purchase is decided on OUR copy of the order, not on what the caller sent: it must be
  -- in the N2S book or the marketplace order book with this event, these seats, this quantity
  -- and this sale price.
  IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'n2s', 'marketplace'], true) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this order is not in our copy of the order books with these seats, quantity and sale price; '
                || 'alert us with the order number only');
  END IF;
  IF public.sub_finder_report_only(o.order_number) THEN                    -- 20261113250000
    RETURN jsonb_build_object('error', 'forbidden',
      'detail', 'this is a PED Need2Buy order: it is reported only and never bought through this API');
  END IF;
  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = o.order_number) THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'the Need-to-Sub auto-buy already has this order');
  END IF;
  -- the sale must still be live (about 1.7 s; last, only for a buy that would otherwise go ahead)
  IF public.sub_finder_order_closed(o.order_number, o.site) IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this sale is marked fulfilled, cancelled or rejected');
  END IF;
  BEGIN
    v_buy := public.manual_sub_buy_request_market(cv->>'market',
      coalesce(o.site, 'CRM'), o.order_number, o.tevo_event_id, (cv->>'listing_id')::bigint,
      (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, o.sold_ea, o.event_name,
      'crm api key ' || coalesce(p_key_label, p_key_id::text)
        || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
      'sub finder job ' || p_job_id || ': sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
        || '; sub ' || (cv->>'section') || ' row ' || (cv->>'row') || ' x' || (cv->>'buy_qty'));
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy already exists for this sale');
  END;
  UPDATE public.sub_finder_order SET buy_id = v_buy, updated_at = now()
   WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('buy_id', v_buy, 'state', 'requested', 'order_number', o.order_number,
                            'market', cv->>'market', 'listing_id', cv->>'listing_id', 'qty', (cv->>'buy_qty')::int,
                            'max_price_ea', (cv->>'price_ea')::numeric);
END
$function$;

-- ── the rebate ceiling ──
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_request(p_key_id bigint, p_key_label text, p_order_number text, p_listing_id text, p_market text DEFAULT NULL::text, p_requested_by text DEFAULT NULL::text, p_rebate_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  o      public.sub_finder_order;
  cv     jsonb;
  v_gate integer;
  v_id   bigint;
  v_back integer;
  v_sale numeric;
  v_max  numeric;                    -- the most a rebate may be (20261116000000)
  v_reb  numeric := nullif(round(p_rebate_amount, 2), 0);   -- 0 = no rebate
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'offer')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'offering subs is not enabled for this key');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE key_id = p_key_id AND order_number = p_order_number AND watching
   ORDER BY updated_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'not_found', 'detail', 'no open lookup holds this order; alert us first');
  END IF;
  IF lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' OR p_order_number !~ '^\d{1,18}$' THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'only GoTickets orders can be offered a sub here');
  END IF;
  -- the offer is decided on OUR copy of the order, not on what the caller sent
  IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'n2s', 'marketplace'], false) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this order is not in our copy of the GoTickets order book with these seats; alert us with the order number only');
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
   WHERE x->>'listing_id' = p_listing_id AND x->>'source' = 'native'
     AND (p_market IS NULL OR x->>'market' = lower(btrim(p_market)))
   ORDER BY n LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'that listing is not a cover this lookup quoted for this order');
  END IF;
  v_gate := (cv->>'gate')::int;
  IF v_gate IS NULL OR (v_gate < 3 AND NOT (public.sub_finder_cover_flags(cv) ? 'single_ticket_row_differs')) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'gate 1-2 covers need no offer: the seats are in the same section, same or better row');
  END IF;
  IF v_gate = 6 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'gate 6 covers are results only and are not offered');
  END IF;
  -- The rebate is the CRM's call: we suggest one (sale total - sub total) but never set it.
  -- Rows back (gate 5) need an explicit answer, 0 included; other gates take one if sent.
  v_sale := round(o.sold_ea * o.qty, 2);
  v_max  := public.sub_finder_rebate_max(v_sale);
  IF v_gate = 5 AND p_rebate_amount IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this sub moves the customer back: send rebate_amount (0 for none)',
      'rebate_suggested', least(greatest((cv->>'profit')::numeric, 0), v_max), 'rebate_max', v_max);
  END IF;
  IF v_reb IS NOT NULL AND (v_reb < 0 OR v_max IS NULL OR v_reb > v_max) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', CASE WHEN v_max IS DISTINCT FROM v_sale
                     THEN 'rebate_amount must be between 0 and the rebate limit (rebate_max)'
                     ELSE 'rebate_amount must be between 0 and the sale total' END,
      'sale_total', v_sale, 'rebate_max', v_max);
  END IF;
  v_back := public.seat_row_rank(cv->>'row') - public.seat_row_rank(o.seat_row);
  BEGIN
    INSERT INTO public.sub_finder_gt_offer
      (job_id, idx, key_id, requested_by, order_number, gt_order_id, gate, market, listing_id, section, seat_row,
       qty, buy_qty, price_ea, order_total, sub_total, rebate_amount, notes)
    VALUES (o.job_id, o.idx, p_key_id,
            'crm api key ' || coalesce(p_key_label, p_key_id::text) || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
            o.order_number, o.order_number::bigint, v_gate, cv->>'market', cv->>'listing_id', cv->>'section', cv->>'row',
            o.qty, (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, round(o.sold_ea * o.qty, 2), (cv->>'total')::numeric,
            v_reb,                                                        -- the amount the CRM gave
            CASE WHEN v_gate = 5
                 THEN 'Replacement seats in the same area, ' || v_back || ' row' || CASE WHEN v_back = 1 THEN '' ELSE 's' END
                      || ' further back than the original row ' || o.seat_row
                      || CASE WHEN v_reb IS NOT NULL THEN ', with a rebate.' ELSE '.' END
                 ELSE 'Comparable replacement seats in the same area, in the same row or closer than the original section '
                      || o.section || ' row ' || o.seat_row || '.' END)
    RETURNING offer_id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'an offer already exists for this order');
  END;
  UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('offer_id', v_id, 'state', 'requested', 'gate', v_gate,
                            'section', cv->>'section', 'row', cv->>'row',
                            'rebate', v_reb);
END
$function$;

-- ── the suggested rebate stays inside the ceiling ──
CREATE OR REPLACE FUNCTION public.sub_finder_offer_json(o sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' THEN NULL
    WHEN r.offer_id IS NULL AND coalesce((o.best->>'gate')::int, 0) < 3
         AND NOT (public.sub_finder_cover_flags(o.best) ? 'single_ticket_row_differs') THEN NULL
    ELSE jsonb_build_object(
      'via', 'gotickets',
      -- true: tell us yes with POST /orders/{n}/offer-sub and this listing_id
      'ask_crm', r.offer_id IS NULL AND o.watching AND o.order_source IN ('api', 'n2s', 'marketplace')
                 AND ((o.best->>'gate')::int IN (3, 4, 5)
                      OR public.sub_finder_cover_flags(o.best) ? 'single_ticket_row_differs'),
      -- true: you may skip the offer and buy the cover outright (buy route, "confirm": true)
      'bypass_allowed', r.offer_id IS NULL AND coalesce((o.best->>'offer_bypass')::boolean, false),
      'results_only', r.offer_id IS NULL AND (o.best->>'gate')::int = 6,
      'gate', coalesce(r.gate, (o.best->>'gate')::int),
      'market', coalesce(r.market, o.best->>'market'),
      'listing_id', coalesce(r.listing_id, o.best->>'listing_id'),
      'section', coalesce(r.section, o.best->>'section'), 'row', coalesce(r.seat_row, o.best->>'row'),
      -- the rebate is yours to set: `rebate` is what was offered; before that, `rebate_needed`
      -- says an amount must come with the yes (rows back) and `rebate_suggested` is sale - sub
      'rebate', r.rebate_amount,
      'rebate_needed', r.offer_id IS NULL AND (o.best->>'gate')::int = 5,
      'rebate_suggested', CASE WHEN r.offer_id IS NULL AND (o.best->>'gate')::int IN (3, 4, 5)
                               THEN least(greatest((o.best->>'profit')::numeric, 0),
                                          public.sub_finder_rebate_max(round(o.sold_ea * o.qty, 2))) END,
      'request', CASE WHEN r.offer_id IS NOT NULL THEN jsonb_build_object(
                   'offer_id', r.offer_id, 'state', r.state, 'reasons', r.reasons,
                   'gotickets_request_id', r.gt_request_id, 'status', r.gt_status,
                   'denial_reason', r.denial_reason, 'status_checked_at', r.status_checked_at,
                   -- after ACCEPTED: 'buy_requested' (see the order's `buy`) or why we did not buy
                   'buy', CASE WHEN r.buy_id IS NOT NULL THEN 'buy_requested' ELSE r.buy_note END,
                   'final_at', r.final_at) END,
      -- the customer said yes: `accepted` flips true (the order's updated_at moves, so it comes
      -- back in the sync feed). `accepted_next` says what happens to the seats:
      --   'buy_requested'   we are buying EVO seats (see the order's `buy`)
      --   'buy_manually'    the offered seats are still listed and we cannot buy them: buy them yourselves
      --   'new_sub_needed'  the offered seats are gone (`offered_gone`) and no one-to-one EVO cover
      --                     was there to buy: `new_best` is the best cover now, with its gate
      'accepted', coalesce(r.gt_status = 'ACCEPTED', false),
      'accepted_at', CASE WHEN r.gt_status = 'ACCEPTED'
                          THEN to_char(r.final_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') END,
      'offered_gone', gn.gone,
      'accepted_next', CASE WHEN r.gt_status IS DISTINCT FROM 'ACCEPTED' THEN NULL
                            WHEN r.buy_id IS NOT NULL OR o.buy_id IS NOT NULL THEN 'buy_requested'
                            WHEN coalesce(gn.gone, false) THEN 'new_sub_needed'
                            ELSE 'buy_manually' END,
      'new_best', CASE WHEN r.gt_status = 'ACCEPTED' AND coalesce(gn.gone, false) AND o.best IS NOT NULL
                       THEN jsonb_build_object(
                              'market', o.best->>'market', 'listing_id', o.best->>'listing_id',
                              'section', o.best->>'section', 'row', o.best->>'row',
                              'gate', (o.best->>'gate')::int, 'label', o.best->>'label',
                              'buy_qty', (o.best->>'buy_qty')::int, 'total', (o.best->>'total')::numeric,
                              'profit', (o.best->>'profit')::numeric) END)
  END
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT g.* FROM public.sub_finder_gt_offer g
                      WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                      ORDER BY g.live DESC, g.offer_id DESC LIMIT 1) r ON true
  LEFT JOIN LATERAL (SELECT public.sub_finder_offer_gone(r, o.tevo_event_id) AS gone WHERE r.offer_id IS NOT NULL) gn ON true;
$function$;

-- ── 5. who may call what ───────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.sub_finder_key_gate(bigint), public.sub_finder_rebate_max(numeric),
  public.sub_finder_audit_log(bigint, bigint, text, text, text, text, text, text, text, integer, jsonb),
  public.sub_finder_idem(bigint, text),
  public.sub_finder_audit_read(bigint, timestamp with time zone, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_key_gate(bigint), public.sub_finder_rebate_max(numeric),
  public.sub_finder_audit_log(bigint, bigint, text, text, text, text, text, text, text, integer, jsonb),
  public.sub_finder_idem(bigint, text),
  public.sub_finder_audit_read(bigint, timestamp with time zone, integer, integer) TO service_role;

NOTIFY pgrst, 'reload schema';
