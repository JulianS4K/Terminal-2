CREATE OR REPLACE FUNCTION public.sub_finder_results(p_key_id bigint, p_updated_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.sub_finder_feed(p_key_id, p_updated_since, p_limit, p_offset, 'n2s')
$function$

