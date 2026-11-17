CREATE OR REPLACE FUNCTION public.sub_finder_crm_limit_pct(p_kind text, p_site text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(
    (SELECT l.pct FROM public.sub_finder_crm_limit l
      WHERE l.kind = p_kind AND l.site = public.sub_finder_site_norm(p_site) AND l.pct IS NOT NULL),
    (SELECT l.pct FROM public.sub_finder_crm_limit l
      WHERE l.kind = p_kind AND l.site = '*' AND l.pct IS NOT NULL));
$function$

