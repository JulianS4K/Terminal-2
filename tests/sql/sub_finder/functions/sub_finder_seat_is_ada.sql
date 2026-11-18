CREATE OR REPLACE FUNCTION public.sub_finder_seat_is_ada(p_section text, p_row text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT public.sub_finder_row_is_wheelchair(p_row)
      OR coalesce(p_section ~* '(^|[^a-z])(wc|ada)([^a-z]|$)'
               OR p_section ~* '[0-9] ?[a-z]?wc([^a-z]|$)'
               OR p_section ~* '(wheelchair|accessible|handicap)', false)
$function$

