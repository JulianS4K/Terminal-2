CREATE OR REPLACE FUNCTION public.sub_finder_cover_flags(cv jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN cv ? 'flags' THEN coalesce(cv->'flags', '[]'::jsonb)
              ELSE to_jsonb(array_remove(ARRAY[
                     CASE WHEN cv->>'label' LIKE '% zone unverified%' THEN 'zone_unverified' END,
                     CASE WHEN cv->>'label' LIKE '% obstructed view%' THEN 'obstructed_view' END,
                     CASE WHEN cv->>'label' LIKE '% wheelchair row%'  THEN 'wheelchair_row' END,
                     CASE WHEN cv->>'label' LIKE '% row letters differ%' THEN 'row_letter_mismatch' END,
                     CASE WHEN cv->>'label' LIKE '% single ticket%' AND cv->>'row_relation' IS DISTINCT FROM 'same'
                          THEN 'single_ticket_row_differs' END,
                     CASE WHEN cv->>'label' LIKE '% repost single%'   THEN 'repost_single' END,
                     CASE WHEN cv->>'label' LIKE '% no sale price%'   THEN 'no_sale_price' END], NULL)) END;
$function$

