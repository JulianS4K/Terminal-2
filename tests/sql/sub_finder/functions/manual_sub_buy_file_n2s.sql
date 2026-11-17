CREATE OR REPLACE FUNCTION public.manual_sub_buy_file_n2s(p_exec_id bigint, p_buy_by timestamp with time zone DEFAULT NULL::timestamp with time zone, p_max_total_usd numeric DEFAULT NULL::numeric)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e     public.n2s_autobuy_exec%ROWTYPE;
  n     public.n2s_autobuy_config%ROWTYPE;
  v_by  timestamptz;
  v_max numeric;
  v_gt  bigint;
  v_id  bigint;
BEGIN
  SELECT * INTO e FROM public.n2s_autobuy_exec WHERE exec_id = p_exec_id;
  IF NOT FOUND OR e.mode IS DISTINCT FROM 'live' OR e.sub_source IS NULL OR e.sub_source NOT IN ('tevo', 'gotickets')
     OR e.sub_listing_id IS NULL OR e.sub_listing_id !~ '^[0-9]{1,18}$'
     OR coalesce(e.qty, 0) < 1 OR coalesce(e.sub_total_usd, 0) <= 0
     OR e.sell_market IS NULL OR e.order_number IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO n FROM public.n2s_autobuy_config WHERE id;
  -- lane D7's rule (bot_chat 6691 E) when the caller passes none: the seller must still have time
  v_by := coalesce(p_buy_by, e.sub_confirm_by - make_interval(secs =>
            GREATEST(coalesce(n.min_confirm_window_s, 0), coalesce(e.seller_window_in_hand_s, 0))));
  v_max := coalesce(p_max_total_usd, round(e.sub_total_usd + coalesce(e.est_tax_usd, 0), 2));
  IF v_by IS NULL OR v_by <= now() OR v_max IS NULL OR v_max <= 0 THEN RETURN NULL; END IF;
  SELECT d.gt_event_id INTO v_gt FROM public.n2s_gt_order_dryrun d WHERE d.dryrun_id = e.dryrun_id;
  BEGIN
    INSERT INTO public.manual_sub_buy
      (requested_by, sale_site, sale_order_number, event_name, tevo_event_id, ticket_group_id, qty,
       max_price_ea, sold_ea, market, gt_event_id, max_total_usd, origin, n2s_exec_id, buy_by)
    VALUES
      (format('n2s auto (exec %s)', e.exec_id), e.sell_market, e.order_number, e.event_name, e.tevo_event_id,
       e.sub_listing_id::bigint, e.qty, round(e.sub_total_usd / e.qty, 4), round(e.sold_total_usd / e.qty, 4),
       CASE e.sub_source WHEN 'tevo' THEN 'evo' ELSE 'gotickets' END, v_gt, v_max, 'n2s', e.exec_id, v_by)
    RETURNING buy_id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN NULL;                    -- this sale already has a live buy, or this exec row was filed before
  END;
  RETURN v_id;
END $function$

