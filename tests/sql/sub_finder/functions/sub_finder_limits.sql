CREATE OR REPLACE FUNCTION public.sub_finder_limits(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a jsonb := public.sub_finder_access(p_key_id);
BEGIN
  IF NOT coalesce((a->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'the sub finder is not enabled for this key');
  END IF;
  RETURN jsonb_build_object(
    'unit', 'percent of the sale total (sale price each x quantity)',
    'rebate_max_pct', jsonb_build_object(
      'what', 'the most rebate_amount may be on an offer',
      'min', 0, 'max', 100, 'not_set_means', 'the sale total',
      'default', (SELECT trim_scale(l.pct) FROM public.sub_finder_crm_limit l WHERE l.kind = 'rebate_max' AND l.site = '*'),
      'by_marketplace', (SELECT coalesce(jsonb_object_agg(l.site, trim_scale(l.pct) ORDER BY l.site), '{}'::jsonb)
                           FROM public.sub_finder_crm_limit l
                          WHERE l.kind = 'rebate_max' AND l.site <> '*' AND l.pct IS NOT NULL)),
    'buy_max_cost_pct', jsonb_build_object(
      'what', 'the most a cover you ask us to buy may cost (100 = no loss)',
      'min', 1, 'max', 1000, 'not_set_means', 'no percentage limit',
      'default', (SELECT trim_scale(l.pct) FROM public.sub_finder_crm_limit l WHERE l.kind = 'buy_max_cost' AND l.site = '*'),
      'by_marketplace', (SELECT coalesce(jsonb_object_agg(l.site, trim_scale(l.pct) ORDER BY l.site), '{}'::jsonb)
                           FROM public.sub_finder_crm_limit l
                          WHERE l.kind = 'buy_max_cost' AND l.site <> '*' AND l.pct IS NOT NULL)),
    'marketplaces', to_jsonb(ARRAY['evo', 'gametime', 'gotickets', 'seatgeek', 'stubhub', 'ticketmaster',
                                   'tickpick', 'viagogo', 'vivid']),
    -- S4K's own ceilings, in dollars; not yours to change
    's4k_ceilings', jsonb_build_object('buy_per_order_usd', a->'limits'->'buy_per_order_usd',
                                       'buy_per_day_usd', a->'limits'->'buy_per_day_usd'),
    'automatic_buy', 'its loss limit is set separately: /settings/auto-buy-loss',
    'can_set', coalesce((a->>'buy')::boolean, false) OR coalesce((a->>'offer')::boolean, false),
    'updated_at', (SELECT max(l.set_at) FROM public.sub_finder_crm_limit l));
END
$function$

