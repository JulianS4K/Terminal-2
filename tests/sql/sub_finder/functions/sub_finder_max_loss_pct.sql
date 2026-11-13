CREATE OR REPLACE FUNCTION public.sub_finder_max_loss_pct(p_site text, p_need2buy boolean)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN coalesce(p_need2buy, false) THEN trim_scale(
    coalesce(
      (SELECT l.max_cost_pct - 100 FROM public.sub_finder_loss_limit l
        WHERE l.site = public.sub_finder_site_norm(p_site) AND l.max_cost_pct IS NOT NULL),
      (SELECT l.max_cost_pct - 100 FROM public.sub_finder_loss_limit l
        WHERE l.site = '*' AND l.max_cost_pct IS NOT NULL),
      (SELECT greatest(c.auto_buy_max_loss_pct, 0) FROM public.sub_finder_config c),
      0)) END;
$function$

