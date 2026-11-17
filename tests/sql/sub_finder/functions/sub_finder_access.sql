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
$function$

