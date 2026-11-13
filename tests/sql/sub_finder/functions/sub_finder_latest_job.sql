CREATE OR REPLACE FUNCTION public.sub_finder_latest_job(p_key_id bigint, p_order_number text)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT o.job_id FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
  WHERE o.key_id = p_key_id AND o.order_number = p_order_number
  ORDER BY j.created_at DESC, o.job_id LIMIT 1;
$function$

