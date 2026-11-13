CREATE OR REPLACE FUNCTION public.sub_finder_cover_buyable(p_order_number text, p_cover jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.sub_finder_market_buyable(p_cover->>'market')
     AND NOT public.sub_finder_listing_tried(p_order_number, p_cover->>'market', p_cover->>'listing_id')
$function$

