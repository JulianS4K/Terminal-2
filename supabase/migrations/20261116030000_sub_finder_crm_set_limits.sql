-- Migration 20261116030000 · level:secondary-sales · lane:D0 · writes:sub_finder_crm_limit,sub_finder_crm_limit_log,sub_finder_crm_limit_pct,sub_finder_rebate_limit,sub_finder_limits,sub_finder_limits_set,sub_finder_access,sub_finder_buy,sub_finder_gt_offer_request,sub_finder_offer_json · reads:sub_finder_config,manual_sub_buy_config,sub_finder_order · pre:20261116020000
--
-- THE CRM SETS ITS OWN LIMITS, AS A PERCENTAGE OF THE SALE.
--
-- 20261116000000 put a ceiling on rebates and it was switched on at 50% of the sale. That number
-- came from nowhere: the CRM had asked for "a ceiling well below the full sale total" and named
-- none. Operator 2026-11-16: "The value should come from crm, allow CRM to set max values for
-- all variables they input as a percentage of total sale value."
--
-- What the CRM inputs that moves money, and the limit it may now put on each
-- (GET / PUT /api/v1/subs/settings/limits):
--
--   rebate_max_pct     the most a rebate on a GoTickets offer may be, 0 to 100 percent of the
--                      sale total. Not set: the sale total, the rule before today.
--   buy_max_cost_pct   the most a cover the CRM asks us to buy may cost, 1 to 1000 percent of
--                      the sale total (100 = no loss). Not set: no percentage limit. Checked in
--                      sub_finder_buy on the quoted total; an order with no sale price cannot
--                      be measured, so it is refused while a limit is set.
--
-- Each has a default and may be set separately for the marketplace the order sold on, exactly
-- like the automatic buy's loss limit (20261113320000), which was already the CRM's to set
-- and is unchanged. Every change is kept in sub_finder_crm_limit_log. The key that sets them
-- must be one that may buy or offer (the router also holds it to its registered address).
--
-- S4K's own ceilings stay and are not the CRM's to change: the dollar caps on one buy and on a
-- day's buys, and sub_finder_config.gt_offer_rebate_max_pct, which is now only an outer bound
-- (the lower of it and the CRM's applies) and is meant to be NULL.
--
-- Nothing here calls a market. Functions of ours are shipped whole (MIGRATION_CONVENTIONS 6a).
--
-- rollback: UPDATE public.sub_finder_crm_limit SET pct = NULL;   (no CRM limit: the rules before today)

-- ── 1. the limits and their history ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sub_finder_crm_limit (
  kind   text NOT NULL CHECK (kind IN ('rebate_max', 'buy_max_cost')),
  site   text NOT NULL,                            -- sub_finder_site_norm() of the marketplace sold on, or '*' = the default
  pct    numeric,                                  -- percent of the sale total; NULL = not set
  set_by text,
  set_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kind, site),
  CHECK (pct IS NULL OR (kind = 'rebate_max' AND pct BETWEEN 0 AND 100) OR (kind = 'buy_max_cost' AND pct BETWEEN 1 AND 1000))
);
CREATE TABLE IF NOT EXISTS public.sub_finder_crm_limit_log (
  id      bigserial PRIMARY KEY,
  at      timestamptz NOT NULL DEFAULT now(),
  key_id  bigint,
  set_by  text,
  kind    text NOT NULL,
  site    text NOT NULL,
  old_pct numeric,
  new_pct numeric
);
ALTER TABLE public.sub_finder_crm_limit     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_finder_crm_limit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_crm_limit, public.sub_finder_crm_limit_log FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.sub_finder_crm_limit IS
  'Sub finder API: the limits the CRM set on its own inputs, as a percent of the sale total. kind rebate_max (0-100) or buy_max_cost (1-1000); site = the marketplace sold on, * = the default; pct NULL = not set. 20261116030000.';

-- The CRM's limit of this kind for an order sold on this marketplace: its own, else the default, else NULL.
CREATE OR REPLACE FUNCTION public.sub_finder_crm_limit_pct(p_kind text, p_site text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(
    (SELECT l.pct FROM public.sub_finder_crm_limit l
      WHERE l.kind = p_kind AND l.site = public.sub_finder_site_norm(p_site) AND l.pct IS NOT NULL),
    (SELECT l.pct FROM public.sub_finder_crm_limit l
      WHERE l.kind = p_kind AND l.site = '*' AND l.pct IS NOT NULL));
$function$;

-- The most a rebate may be, in dollars, on a sale of this total sold on this marketplace: the
-- lower of the CRM's limit and S4K's own outer bound; neither set, the sale total.
CREATE OR REPLACE FUNCTION public.sub_finder_rebate_limit(p_sale_total numeric, p_site text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN x.pct IS NULL THEN p_sale_total ELSE round(p_sale_total * x.pct / 100.0, 2) END
    FROM (SELECT least(c.gt_offer_rebate_max_pct, public.sub_finder_crm_limit_pct('rebate_max', p_site)) AS pct
            FROM public.sub_finder_config c) x;
$function$;

-- GET /api/v1/subs/settings/limits
CREATE OR REPLACE FUNCTION public.sub_finder_limits(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a jsonb := public.sub_finder_access(p_key_id);
BEGIN
  IF NOT coalesce((a->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'the sub finder is not enabled for this key');
  END IF;
  RETURN jsonb_build_object(
    'unit', 'percent of the sale total (sale price each x quantity)',
    'rebate_max_pct', jsonb_build_object(
      'what', 'the most rebate_amount may be on an offer',
      'min', 0, 'max', 100, 'not_set_means', 'the sale total',
      'default', (SELECT trim_scale(l.pct) FROM public.sub_finder_crm_limit l WHERE l.kind = 'rebate_max' AND l.site = '*'),
      'by_marketplace', (SELECT coalesce(jsonb_object_agg(l.site, trim_scale(l.pct) ORDER BY l.site), '{}'::jsonb)
                           FROM public.sub_finder_crm_limit l
                          WHERE l.kind = 'rebate_max' AND l.site <> '*' AND l.pct IS NOT NULL)),
    'buy_max_cost_pct', jsonb_build_object(
      'what', 'the most a cover you ask us to buy may cost (100 = no loss)',
      'min', 1, 'max', 1000, 'not_set_means', 'no percentage limit',
      'default', (SELECT trim_scale(l.pct) FROM public.sub_finder_crm_limit l WHERE l.kind = 'buy_max_cost' AND l.site = '*'),
      'by_marketplace', (SELECT coalesce(jsonb_object_agg(l.site, trim_scale(l.pct) ORDER BY l.site), '{}'::jsonb)
                           FROM public.sub_finder_crm_limit l
                          WHERE l.kind = 'buy_max_cost' AND l.site <> '*' AND l.pct IS NOT NULL)),
    'marketplaces', to_jsonb(ARRAY['evo', 'gametime', 'gotickets', 'seatgeek', 'stubhub', 'ticketmaster',
                                   'tickpick', 'viagogo', 'vivid']),
    -- S4K's own ceilings, in dollars; not yours to change
    's4k_ceilings', jsonb_build_object('buy_per_order_usd', a->'limits'->'buy_per_order_usd',
                                       'buy_per_day_usd', a->'limits'->'buy_per_day_usd'),
    'automatic_buy', 'its loss limit is set separately: /settings/auto-buy-loss',
    'can_set', coalesce((a->>'buy')::boolean, false) OR coalesce((a->>'offer')::boolean, false),
    'updated_at', (SELECT max(l.set_at) FROM public.sub_finder_crm_limit l));
END
$function$;

-- PUT /api/v1/subs/settings/limits. All of it is valid or nothing changes.
CREATE OR REPLACE FUNCTION public.sub_finder_limits_set(p_key_id bigint, p_key_label text, p_body jsonb, p_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a     jsonb := public.sub_finder_access(p_key_id);
  v_by  text := 'crm api key ' || coalesce(p_key_label, p_key_id::text) || coalesce(' / ' || nullif(btrim(p_by), ''), '');
  v_set jsonb := '[]'::jsonb;        -- [{kind, site, pct}], validated
  k     record;
  r     record;
  v_one jsonb;
  v_site text;
  v_hint constant text := 'send {"rebate_max_pct": {"default": 0-100 or null, "by_marketplace": {"<marketplace>": 0-100 or null}}, '
                          || '"buy_max_cost_pct": {"default": 1-1000 or null, "by_marketplace": {...}}}; either may be left out';
BEGIN
  IF NOT (coalesce((a->>'find')::boolean, false)
          AND (coalesce((a->>'buy')::boolean, false) OR coalesce((a->>'offer')::boolean, false))) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not set limits');
  END IF;
  IF jsonb_typeof(p_body) IS DISTINCT FROM 'object' OR NOT (p_body ? 'rebate_max_pct' OR p_body ? 'buy_max_cost_pct') THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', v_hint);
  END IF;
  FOR k IN SELECT * FROM (VALUES ('rebate_max_pct', 'rebate_max', 0, 100), ('buy_max_cost_pct', 'buy_max_cost', 1, 1000)) v(field, kind, lo, hi)
            WHERE p_body ? v.field
  LOOP
    v_one := p_body->k.field;
    IF jsonb_typeof(v_one) <> 'object' OR NOT (v_one ? 'default' OR v_one ? 'by_marketplace')
       OR (v_one ? 'by_marketplace' AND jsonb_typeof(v_one->'by_marketplace') <> 'object') THEN
      RETURN jsonb_build_object('error', 'invalid', 'detail', k.field || ': ' || v_hint);
    END IF;
    FOR r IN
      SELECT '*' AS name, v_one->'default' AS v WHERE v_one ? 'default'
      UNION ALL
      SELECT e.key, e.value FROM jsonb_each(coalesce(v_one->'by_marketplace', '{}'::jsonb)) e
    LOOP
      v_site := CASE WHEN r.name = '*' THEN '*' ELSE public.sub_finder_site_norm(r.name) END;
      IF v_site IS NULL OR (r.name <> '*' AND v_site = '*') THEN
        RETURN jsonb_build_object('error', 'invalid', 'detail', k.field || ': not a marketplace name: ' || r.name);
      END IF;
      IF jsonb_typeof(r.v) = 'null' THEN
        v_set := v_set || jsonb_build_object('kind', k.kind, 'site', v_site, 'pct', NULL);
      ELSIF jsonb_typeof(r.v) = 'number' AND (r.v)::text::numeric BETWEEN k.lo AND k.hi THEN
        v_set := v_set || jsonb_build_object('kind', k.kind, 'site', v_site, 'pct', round((r.v)::text::numeric, 2));
      ELSE
        RETURN jsonb_build_object('error', 'invalid',
          'detail', k.field || ' for ' || CASE WHEN r.name = '*' THEN 'the default' ELSE r.name END
                    || ' must be a number from ' || k.lo || ' to ' || k.hi || ' (percent of the sale total), or null');
      END IF;
    END LOOP;
  END LOOP;
  FOR r IN SELECT e->>'kind' AS kind, e->>'site' AS site,
                  CASE WHEN jsonb_typeof(e->'pct') = 'null' THEN NULL ELSE (e->'pct')::text::numeric END AS pct
             FROM jsonb_array_elements(v_set) e
  LOOP
    INSERT INTO public.sub_finder_crm_limit_log (key_id, set_by, kind, site, old_pct, new_pct)
    VALUES (p_key_id, v_by, r.kind, r.site,
            (SELECT l.pct FROM public.sub_finder_crm_limit l WHERE l.kind = r.kind AND l.site = r.site), r.pct);
    INSERT INTO public.sub_finder_crm_limit (kind, site, pct, set_by, set_at)
    VALUES (r.kind, r.site, r.pct, v_by, now())
    ON CONFLICT (kind, site) DO UPDATE SET pct = excluded.pct, set_by = excluded.set_by, set_at = now();
  END LOOP;
  RETURN public.sub_finder_limits(p_key_id);
END
$function$;

-- ── 2. our own functions, whole ────────────────────────────────────────────

-- ── the CRM's own default limits in the access answer ──
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
      -- 20261116030000: the CRM's own default limits (GET /settings/limits has them by marketplace);
      -- for rebates the lower of the CRM's and S4K's outer bound
      'rebate_max_pct', least(c.gt_offer_rebate_max_pct, public.sub_finder_crm_limit_pct('rebate_max', '*')),
      'buy_max_cost_pct', public.sub_finder_crm_limit_pct('buy_max_cost', '*')))
  FROM public.sub_finder_config c LEFT JOIN public.manual_sub_buy_config m ON true;
$function$;

-- ── the CRM's limit on a buy's cost ──
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
  v_pct numeric;                     -- the CRM's own limit on a buy's cost, % of the sale (20261116030000)
  v_sale numeric;
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
    -- one cap check + request at a time: held to the end of the transaction, so two buys for
    -- different orders cannot both read the same total and together pass the limit
    PERFORM pg_advisory_xact_lock(hashtext('sub_finder_crm_buy_cap'));
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
  -- 20261116030000: the CRM's own limit on what a cover it asks for may cost, as a percent of
  -- the sale total, for the marketplace the order sold on. Not set: no percentage limit. An
  -- order with no sale price cannot be measured, so it is refused while a limit is set.
  v_pct := public.sub_finder_crm_limit_pct('buy_max_cost', o.site);
  IF v_pct IS NOT NULL THEN
    v_sale := round(o.sold_ea * o.qty, 2);
    IF v_sale IS NULL OR v_sale <= 0 OR (cv->>'total')::numeric > round(v_sale * v_pct / 100.0, 2) THEN
      RETURN jsonb_build_object('error', 'forbidden',
        'detail', CASE WHEN v_sale IS NULL OR v_sale <= 0
                       THEN 'this order has no sale price to measure your buy limit against'
                       ELSE 'this buy costs more than your limit for one buy (buy_max_cost_pct)' END,
        'limit', 'buy_max_cost_pct', 'limit_pct', trim_scale(v_pct), 'sale_total', v_sale,
        'max_usd', round(v_sale * v_pct / 100.0, 2), 'this_buy_usd', (cv->>'total')::numeric);
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

-- ── the rebate limit is the CRM's ──
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
  v_max  := public.sub_finder_rebate_limit(v_sale, o.site);   -- the CRM's own limit (20261116030000)
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

-- ── the suggested rebate stays inside the CRM's limit ──
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
                                          public.sub_finder_rebate_limit(round(o.sold_ea * o.qty, 2), o.site)) END,
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

-- ── 3. who may call what ───────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.sub_finder_crm_limit_pct(text, text), public.sub_finder_rebate_limit(numeric, text),
  public.sub_finder_limits(bigint), public.sub_finder_limits_set(bigint, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_crm_limit_pct(text, text), public.sub_finder_rebate_limit(numeric, text),
  public.sub_finder_limits(bigint), public.sub_finder_limits_set(bigint, text, jsonb, text) TO service_role;

NOTIFY pgrst, 'reload schema';
