CREATE OR REPLACE FUNCTION public.sub_finder_need2buy(p_status text, p_status_label text, p_raw jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(bool_or(lower(regexp_replace(v, '[^A-Za-z0-9]', '', 'g')) IN ('need2buy', 'needtobuy', 'n2b')), false)
    FROM unnest(ARRAY[p_status, p_status_label, p_raw->>'label_status']) v;
$function$

