CREATE OR REPLACE FUNCTION public.manual_sub_buy_total_ceiling(b manual_sub_buy)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN b.requested_by LIKE 'sub finder auto (key %' AND b.sold_ea > 0
              THEN round(b.sold_ea * b.qty * (1 + greatest(coalesce(c.auto_buy_max_loss_pct, 0), 0) / 100.0), 2) END
  FROM (SELECT 1) one LEFT JOIN public.sub_finder_config c ON c.id;
$function$

