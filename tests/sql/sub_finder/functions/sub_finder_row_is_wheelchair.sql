CREATE OR REPLACE FUNCTION public.sub_finder_row_is_wheelchair(p_row text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT coalesce(p_row ~* '(^|[^a-z])(wc|ada)([^a-z]|$)' OR p_row ~* '(wheelchair|accessible|handicap)', false)
$function$

