CREATE OR REPLACE FUNCTION public.sub_finder_covers_key(p jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(jsonb_agg(x - 'listing_seen_at' ORDER BY ord), '[]'::jsonb)
  FROM jsonb_array_elements(coalesce(p, '[]'::jsonb)) WITH ORDINALITY t(x, ord);
$function$

