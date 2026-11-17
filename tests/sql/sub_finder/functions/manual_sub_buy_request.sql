CREATE OR REPLACE FUNCTION public.manual_sub_buy_request(p_sale_site text, p_sale_order_number text, p_tevo_event_id bigint, p_ticket_group_id bigint, p_qty integer, p_max_price_ea numeric, p_sold_ea numeric DEFAULT NULL::numeric, p_event_name text DEFAULT NULL::text, p_requested_by text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF COALESCE(btrim(p_sale_site), '') = '' OR COALESCE(btrim(p_sale_order_number), '') = '' THEN
    RAISE EXCEPTION 'manual_sub_buy_request: the sale site and order number are required';
  END IF;
  IF COALESCE(btrim(p_requested_by), '') = '' THEN
    RAISE EXCEPTION 'manual_sub_buy_request: requested_by is required (who chose this buy)';
  END IF;
  INSERT INTO public.manual_sub_buy (requested_by, sale_site, sale_order_number, event_name, tevo_event_id,
                                     ticket_group_id, qty, max_price_ea, sold_ea, note)
  VALUES (btrim(p_requested_by), btrim(p_sale_site), btrim(p_sale_order_number), p_event_name, p_tevo_event_id,
          p_ticket_group_id, p_qty, p_max_price_ea, p_sold_ea, p_note)
  RETURNING buy_id INTO v_id;
  RETURN v_id;
END $function$

