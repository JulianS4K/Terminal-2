CREATE OR REPLACE FUNCTION public.sub_finder_autobuy_gate(x jsonb, p_max_loss_pct numeric)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(
    (x->>'gate')::int = 1
    OR (p_max_loss_pct IS NOT NULL
        AND (x->>'gate')::int = 2
        AND (x->>'profit')::numeric <= 0
        AND (x->>'total')::numeric + (x->>'profit')::numeric > 0
        AND -(x->>'profit')::numeric
            <= ((x->>'total')::numeric + (x->>'profit')::numeric) * p_max_loss_pct / 100.0),
    false);
$function$

