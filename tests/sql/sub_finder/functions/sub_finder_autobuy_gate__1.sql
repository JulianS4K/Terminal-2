CREATE OR REPLACE FUNCTION public.sub_finder_autobuy_gate(x jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(
    (x->>'gate')::int = 1
    OR ((x->>'gate')::int = 2
        AND (x->>'profit')::numeric <= 0
        AND (x->>'total')::numeric + (x->>'profit')::numeric > 0
        AND -(x->>'profit')::numeric
            <= ((x->>'total')::numeric + (x->>'profit')::numeric)
               * (SELECT c.auto_buy_max_loss_pct FROM public.sub_finder_config c) / 100.0),
    false);
$function$

