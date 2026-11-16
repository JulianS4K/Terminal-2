CREATE OR REPLACE FUNCTION public.sub_finder_row_letters_differ(p_sold text, p_sub text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT coalesce(btrim(p_sold) ~ '^[A-Za-z]{1,2}$' AND btrim(p_sub) ~ '^[A-Za-z]{1,2}$'
                  AND length(btrim(p_sold)) <> length(btrim(p_sub))
                  AND NOT public.sub_finder_row_is_wheelchair(p_sold)
                  AND NOT public.sub_finder_row_is_wheelchair(p_sub), false)
$function$

