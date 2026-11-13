CREATE OR REPLACE FUNCTION public.sub_finder_report_only(p_order_number text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.n2s_items n
                  WHERE n.item_source = 'gmail'
                    AND (n.order_number = p_order_number OR n.n2s_order_key = p_order_number))
$function$

