CREATE OR REPLACE FUNCTION public.sub_finder_rebate_limit(p_sale_total numeric, p_site text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN x.pct IS NULL THEN p_sale_total ELSE round(p_sale_total * x.pct / 100.0, 2) END
    FROM (SELECT least(c.gt_offer_rebate_max_pct, public.sub_finder_crm_limit_pct('rebate_max', p_site)) AS pct
            FROM public.sub_finder_config c) x;
$function$

