CREATE OR REPLACE FUNCTION public.sub_finder_rebate_max(p_sale_total numeric)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN c.gt_offer_rebate_max_pct IS NULL THEN p_sale_total
              ELSE round(p_sale_total * c.gt_offer_rebate_max_pct / 100.0, 2) END
    FROM public.sub_finder_config c;
$function$

