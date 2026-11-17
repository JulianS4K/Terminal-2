CREATE OR REPLACE FUNCTION public.sub_finder_loss_limits(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c     public.sub_finder_config;
  v_def numeric;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'the sub finder is not enabled for this key');
  END IF;
  v_def := 100 + public.sub_finder_max_loss_pct('*', true);
  RETURN jsonb_build_object(
    'applies_to', 'need2buy orders only; every other order is bought automatically at a profit only',
    'unit', 'the most an automatic buy may cost, as a percent of the sale total (100 = no loss, 105 = a 5% loss)',
    'min', 100, 'max', 200,
    'default_max_cost_pct', v_def,
    'by_marketplace', (SELECT coalesce(jsonb_object_agg(l.site, trim_scale(l.max_cost_pct) ORDER BY l.site), '{}'::jsonb)
                         FROM public.sub_finder_loss_limit l WHERE l.site <> '*' AND l.max_cost_pct IS NOT NULL),
    'marketplaces', to_jsonb(ARRAY['evo', 'gametime', 'gotickets', 'seatgeek', 'stubhub', 'ticketmaster',
                                   'tickpick', 'viagogo', 'vivid']),
    'can_set', p_key_id = ANY (c.loss_limit_key_ids),
    'updated_at', (SELECT max(l.set_at) FROM public.sub_finder_loss_limit l));
END
$function$

