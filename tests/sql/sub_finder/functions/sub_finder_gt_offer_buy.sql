CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_buy(p_offer_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config;
  r       public.sub_finder_gt_offer;
  o       public.sub_finder_order;
  v_note  text;
  v_buy   bigint;
  v_spent numeric;
  v_label text;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  PERFORM pg_advisory_xact_lock(hashtext('sub_finder_autobuy'));      -- one cap check + request at a time
  SELECT * INTO r FROM public.sub_finder_gt_offer WHERE offer_id = p_offer_id FOR UPDATE;
  IF NOT FOUND OR r.gt_status IS DISTINCT FROM 'ACCEPTED' OR r.buy_id IS NOT NULL OR r.buy_note IS NOT NULL THEN
    RETURN NULL;                                                      -- not accepted, or already decided
  END IF;
  SELECT * INTO o FROM public.sub_finder_order WHERE job_id = r.job_id AND idx = r.idx FOR UPDATE;
  v_note := CASE
    -- every switch above this one must be on too: the API, GoTickets offers, and this buy
    WHEN NOT (c.enabled AND c.gt_offer_enabled AND c.gt_offer_auto_buy) THEN 'auto_buy_off'
    WHEN NOT o.watching
      OR public.sub_finder_order_closed(r.order_number, 'GoTickets') IS NOT NULL
      THEN 'order_closed'
    WHEN public.sub_finder_report_only(r.order_number) THEN 'report_only'   -- 20261113250000
    WHEN NOT public.sub_finder_market_buyable(r.market) THEN 'not_on_evo'
    WHEN r.buy_qty <> r.qty THEN 'needs_spare_ticket'
    WHEN o.buy_id IS NOT NULL
      OR EXISTS (SELECT 1 FROM public.manual_sub_buy b WHERE b.sale_order_number = r.order_number
                    AND b.state IN ('requested', 'buying', 'bought', 'unknown'))
      OR EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = r.order_number)
      THEN 'already_bought_for_this_sale'
  END;
  IF v_note IS NULL THEN
    SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
      FROM public.manual_sub_buy b
     WHERE b.requested_by LIKE 'sub finder auto%' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
       AND (b.created_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date;
    IF v_spent + r.price_ea * r.buy_qty > c.auto_buy_daily_cap_usd THEN v_note := 'over_daily_cap'; END IF;
  END IF;
  IF v_note IS NULL THEN
    SELECT key_label INTO v_label FROM public.sub_finder_job WHERE job_id = r.job_id;
    BEGIN
      v_buy := public.manual_sub_buy_request_market(r.market,
        'GoTickets', r.order_number, o.tevo_event_id, r.listing_id::bigint, r.buy_qty, r.price_ea, o.sold_ea,
        o.event_name, 'sub finder auto (gotickets offer accepted, key ' || coalesce(v_label, r.key_id::text) || ')',
        'customer accepted GoTickets substitution ' || r.gt_request_id || ' (gate ' || r.gate || '): sub '
          || r.section || ' row ' || r.seat_row || ' x' || r.buy_qty
          || coalesce(', rebate ' || r.rebate_amount, ''));
    EXCEPTION WHEN unique_violation THEN
      v_note := 'already_bought_for_this_sale';
    END;
  END IF;
  UPDATE public.sub_finder_gt_offer SET buy_id = v_buy, buy_note = v_note, updated_at = now() WHERE offer_id = p_offer_id;
  UPDATE public.sub_finder_order
     SET buy_id = coalesce(v_buy, buy_id), action = CASE WHEN v_buy IS NOT NULL THEN 'auto_bought' ELSE action END,
         updated_at = now()
   WHERE job_id = r.job_id AND idx = r.idx;
  RETURN coalesce(v_note, 'buy_requested');
END
$function$

