CREATE OR REPLACE FUNCTION public.manual_sub_buy_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c        public.manual_sub_buy_config%ROWTYPE;
  b        public.manual_sub_buy%ROWTYPE;
  v_total  numeric;
  v_spent  numeric;
  v_today  date := (now() AT TIME ZONE 'America/New_York')::date;
  r        text[] := '{}';
BEGIN
  -- FOR UPDATE serializes claims, so two workers see each other's spend and never share a row.
  SELECT * INTO c FROM public.manual_sub_buy_config WHERE id FOR UPDATE;

  -- A row left in 'buying' past its lease means a worker died around the buy: the outcome is
  -- unknown. It is NEVER handed out again (that could buy twice); everything stops for a person.
  UPDATE public.manual_sub_buy
     SET state = 'unknown', reasons = reasons || 'worker_lost_mid_buy'::text, updated_at = now(),
         lease_token = NULL
   WHERE state = 'buying' AND lease_until < now();
  IF FOUND THEN
    UPDATE public.manual_sub_buy_config
       SET kill_switch = true, kill_reason = 'a buy was left unfinished: check EVO and GoTickets', updated_at = now()
     WHERE id;
    RETURN NULL;
  END IF;

  IF NOT c.enabled OR c.kill_switch THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.manual_sub_buy WHERE state IN ('buying', 'unknown')) THEN
    RETURN NULL;                                        -- one at a time; nothing while one is unresolved
  END IF;

  SELECT * INTO b FROM public.manual_sub_buy
   WHERE state = 'requested' ORDER BY created_at, buy_id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;

  v_total := round(b.max_price_ea * b.qty, 2);
  SELECT COALESCE(sum(COALESCE(bought_total_usd, round(max_price_ea * qty, 2))), 0) INTO v_spent
    FROM public.manual_sub_buy
   WHERE state IN ('bought', 'unknown') AND (updated_at AT TIME ZONE 'America/New_York')::date = v_today
     AND market = b.market;                             -- each market spends against its own ceiling
  IF b.market = 'gotickets' AND NOT c.gt_enabled THEN r := r || 'gotickets_buy_off'::text; END IF;
  IF v_total > (CASE b.market WHEN 'gotickets' THEN coalesce(c.gt_per_order_cap_usd, c.per_order_cap_usd)
                              ELSE c.per_order_cap_usd END)
    THEN r := r || 'over_order_cap'::text; END IF;
  IF v_spent + v_total > (CASE b.market WHEN 'gotickets' THEN coalesce(c.gt_daily_cap_usd, c.daily_cap_usd)
                                        ELSE c.daily_cap_usd END)
    THEN r := r || 'over_daily_cap'::text; END IF;
  IF cardinality(r) > 0 THEN
    UPDATE public.manual_sub_buy SET state = 'stopped', reasons = r, updated_at = now() WHERE buy_id = b.buy_id;
    RETURN NULL;
  END IF;

  UPDATE public.manual_sub_buy
     SET state = 'buying', lease_token = gen_random_uuid(),
         lease_until = now() + make_interval(secs => c.lease_s), updated_at = now(),
         max_total_usd = public.manual_sub_buy_total_ceiling(b)
   WHERE buy_id = b.buy_id
  RETURNING * INTO b;

  RETURN jsonb_build_object(
    'row', to_jsonb(b),
    'cfg', jsonb_build_object('evo_buyer_office_id', c.evo_buyer_office_id,
                              'evo_email_address_id', c.evo_email_address_id,
                              'tax_quote', c.tax_quote,
                              'gt_buyer_email', c.gt_buyer_email, 'gt_buyer_phone', c.gt_buyer_phone,
                              'gt_billing_address', c.gt_billing_address, 'gt_recipient', c.gt_recipient,
                              'gt_gift_card_ids', to_jsonb(c.gt_gift_card_ids),
                              -- the first run is a test: ask, store the answer, change nothing else
                              'tax_quote_test', c.tax_quote_test AND NOT c.tax_quote
                                AND NOT EXISTS (SELECT 1 FROM public.manual_sub_buy q WHERE q.quote_raw IS NOT NULL)));
END $function$

