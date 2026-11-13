CREATE OR REPLACE FUNCTION public.sub_finder_order_verified(o sub_finder_order, p_books text[], p_need_price boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH l AS MATERIALIZED (SELECT * FROM public.sub_finder_lookup(o.order_number)),
  newest AS (
    SELECT DISTINCT ON (l.book) l.* FROM l
     WHERE l.book = ANY (p_books)
       AND public.sub_finder_site_norm(l.site) = public.sub_finder_site_norm(o.site)
     ORDER BY l.book, l.pulled_at DESC NULLS LAST)
  SELECT o.tevo_event_id IS NOT NULL
     AND public.sub_finder_site_norm(o.site) IS NOT NULL
     AND (SELECT count(DISTINCT coalesce(public.sub_finder_site_norm(l.site), '?')) FROM l) = 1
     AND EXISTS (SELECT 1 FROM newest n
                  WHERE n.tevo_event_id = o.tevo_event_id
                    AND public.seat_section_norm(n.section) = public.seat_section_norm(o.section)
                    AND upper(btrim(n.seat_row)) = upper(btrim(o.seat_row)) AND n.qty = o.qty
                    AND (NOT p_need_price OR abs(n.sold_ea - o.sold_ea) <= 0.01));
$function$

