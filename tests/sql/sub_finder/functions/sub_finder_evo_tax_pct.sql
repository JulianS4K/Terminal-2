CREATE OR REPLACE FUNCTION public.sub_finder_evo_tax_pct(p_market text, p_venue_id bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN p_market = 'evo'
              THEN coalesce((SELECT t.tax_pct FROM public.evo_venue_tax t WHERE t.venue_id = p_venue_id),
                            (SELECT c.evo_tax_default_pct FROM public.sub_finder_config c), 0)
              ELSE 0 END;
$function$

