CREATE OR REPLACE FUNCTION public.manual_sub_buy_request_market(p_market text, p_sale_site text, p_sale_order_number text, p_tevo_event_id bigint, p_listing_id bigint, p_qty integer, p_max_price_ea numeric, p_sold_ea numeric DEFAULT NULL::numeric, p_event_name text DEFAULT NULL::text, p_requested_by text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_market text := lower(coalesce(btrim(p_market), 'evo'));
  v_id     bigint;
  v_event  bigint;
BEGIN
  IF v_market NOT IN ('evo', 'gotickets') THEN
    RAISE EXCEPTION 'manual_sub_buy_request_market: cannot buy on market %', p_market;
  END IF;
  v_id := public.manual_sub_buy_request(p_sale_site, p_sale_order_number, p_tevo_event_id, p_listing_id,
                                        p_qty, p_max_price_ea, p_sold_ea, p_event_name, p_requested_by, p_note);
  IF v_market = 'gotickets' THEN
    SELECT g.gt_event_id INTO v_event FROM public.n2s_gt_current g
     WHERE g.gt_listing_id = p_listing_id AND g.tevo_event_id = p_tevo_event_id AND g.gt_event_id IS NOT NULL
     ORDER BY g.pulled_at DESC LIMIT 1;
    IF v_event IS NULL THEN
      SELECT e.gt_event_id INTO v_event FROM public.gotickets_event e
       WHERE e.tevo_event_id = p_tevo_event_id ORDER BY e.gt_event_id LIMIT 1;
    END IF;
    UPDATE public.manual_sub_buy SET market = 'gotickets', gt_event_id = v_event WHERE buy_id = v_id;
  END IF;
  RETURN v_id;
END
$function$

