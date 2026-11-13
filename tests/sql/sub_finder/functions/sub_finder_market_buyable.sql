CREATE OR REPLACE FUNCTION public.sub_finder_market_buyable(p_market text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT p_market = 'evo'
      OR (p_market = 'gotickets'
          AND coalesce((SELECT gt_buy_enabled FROM public.sub_finder_config), false)
          AND coalesce((SELECT gt_enabled FROM public.manual_sub_buy_config), false))   -- both switches
$function$

