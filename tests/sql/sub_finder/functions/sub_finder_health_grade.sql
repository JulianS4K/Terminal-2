CREATE OR REPLACE FUNCTION public.sub_finder_health_grade(p_age_s numeric, p_ok_s integer, p_degraded_s integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE WHEN p_age_s IS NULL THEN 'down'
              WHEN p_age_s <= p_ok_s THEN 'ok'
              WHEN p_age_s <= p_degraded_s THEN 'degraded'
              ELSE 'down' END;
$function$

