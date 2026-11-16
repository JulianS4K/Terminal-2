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
$function$

