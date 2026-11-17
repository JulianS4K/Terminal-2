CREATE OR REPLACE FUNCTION public.sub_finder_listing_tried(p_order_number text, p_market text, p_listing_id text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.manual_sub_buy b
     WHERE b.sale_order_number = p_order_number AND b.market = p_market
       AND b.ticket_group_id::text = p_listing_id AND b.state = 'stopped'
       AND b.updated_at > now() - (SELECT buy_fallback_retry FROM public.sub_finder_config))
$function$

