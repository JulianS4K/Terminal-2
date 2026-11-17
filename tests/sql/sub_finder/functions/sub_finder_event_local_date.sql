CREATE OR REPLACE FUNCTION public.sub_finder_event_local_date(p_tevo_event_id bigint)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN e.occurs_at_local::text ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN left(e.occurs_at_local::text, 10)::date END
    FROM public.events e WHERE e.id = p_tevo_event_id
$function$

