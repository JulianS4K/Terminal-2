CREATE OR REPLACE FUNCTION public.sub_finder_idem(p_account_id bigint, p_idem_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object('action', a.action, 'order_number', a.order_number, 'listing_id', a.listing_id,
                            'response', a.response)
    FROM public.sub_finder_audit a
   WHERE a.account_id = p_account_id AND a.idem_key = p_idem_key AND a.http_status = 202;
$function$

