CREATE OR REPLACE FUNCTION public.sub_finder_offer_pending(p_order_number text, p_key_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g
                  WHERE g.order_number = p_order_number AND g.key_id = p_key_id AND g.live
                    AND g.gt_status IS DISTINCT FROM 'ACCEPTED');
$function$

