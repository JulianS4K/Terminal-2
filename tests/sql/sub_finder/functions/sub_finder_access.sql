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
    'max_orders_per_job', c.max_orders_per_job, 'ticketsdata_fallback', c.td_enabled)
  FROM public.sub_finder_config c;
$function$

