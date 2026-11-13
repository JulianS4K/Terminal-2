CREATE OR REPLACE FUNCTION public.sub_finder_bg_settle()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce((SELECT c.bg_settle_enabled FROM public.sub_finder_config c), false)
$function$

