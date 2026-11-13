CREATE OR REPLACE FUNCTION public.sub_finder_td_wanted(p_scope text, p_state text, p_best jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN p_state = 'no_cover' THEN true
    WHEN p_state <> 'cover'   THEN false
    WHEN p_scope = 'all'      THEN true
    WHEN p_scope = 'not_one_to_one' THEN coalesce((p_best ->> 'gate')::int, 9) > 1
    ELSE false END
$function$

