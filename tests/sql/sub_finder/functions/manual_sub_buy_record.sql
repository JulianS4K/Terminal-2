CREATE OR REPLACE FUNCTION public.manual_sub_buy_record(p_buy_id bigint, p_token uuid, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_state text := p_patch->>'state';
BEGIN
  IF v_state IS NULL OR v_state NOT IN ('buying', 'bought', 'stopped', 'unknown') THEN
    RAISE EXCEPTION 'manual_sub_buy_record: bad state %', v_state;
  END IF;
  UPDATE public.manual_sub_buy
     SET state            = v_state,
         reasons          = CASE WHEN p_patch ? 'reasons'
                                 THEN ARRAY(SELECT jsonb_array_elements_text(p_patch->'reasons')) ELSE reasons END,
         buy_order_id     = COALESCE(p_patch->>'buy_order_id', buy_order_id),
         buy_state        = COALESCE(p_patch->>'buy_state', buy_state),
         bought_price_ea  = COALESCE((p_patch->>'bought_price_ea')::numeric, bought_price_ea),
         bought_total_usd = COALESCE((p_patch->>'bought_total_usd')::numeric, bought_total_usd),
         quote_tax_usd    = COALESCE((p_patch->>'quote_tax_usd')::numeric, quote_tax_usd),
         quote_total_usd  = COALESCE((p_patch->>'quote_total_usd')::numeric, quote_total_usd),
         quote_raw        = COALESCE(p_patch->'quote_raw', quote_raw),
         error            = COALESCE(p_patch->>'error', error),
         lease_token      = CASE WHEN v_state = 'buying' THEN lease_token END,
         updated_at       = now()
   WHERE buy_id = p_buy_id AND state = 'buying' AND lease_token = p_token AND lease_until >= now();
  IF NOT FOUND THEN
    RETURN 'lease_lost';
  END IF;
  IF v_state = 'unknown' THEN
    UPDATE public.manual_sub_buy_config
       SET kill_switch = true, updated_at = now(),
           kill_reason = format('buy %s: outcome unknown, %s', p_buy_id,
                                (SELECT CASE b.market WHEN 'gotickets' THEN 'check GoTickets' ELSE 'check EVO' END
                                   FROM public.manual_sub_buy b WHERE b.buy_id = p_buy_id))
     WHERE id;
  END IF;
  RETURN v_state;
END $function$

