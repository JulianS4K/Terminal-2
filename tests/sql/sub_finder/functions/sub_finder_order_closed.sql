CREATE OR REPLACE FUNCTION public.sub_finder_order_closed(p_order text, p_site text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT l.status FROM public.sub_finder_lookup(p_order) l
   WHERE NOT l.is_open AND l.book <> 'n2s' AND l.status IN ('fulfilled', 'cancelled', 'rejected')
     AND (public.sub_finder_site_norm(p_site) IS NULL OR public.sub_finder_site_norm(l.site) IS NULL
          OR public.sub_finder_site_norm(l.site) = public.sub_finder_site_norm(p_site))
   ORDER BY l.rnk, l.pulled_at DESC NULLS LAST LIMIT 1;
$function$

