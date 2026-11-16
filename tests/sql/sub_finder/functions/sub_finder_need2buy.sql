CREATE OR REPLACE FUNCTION public.sub_finder_need2buy(p_status text, p_status_label text, p_raw jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- 20261116000000 (the CRM's request): `status` equal to `need2buy`, exactly. No other field
  -- and no other spelling starts a lookup that may buy. The other two arguments are kept so
  -- callers do not change; they are not read.
  SELECT coalesce(p_status = 'need2buy', false);
$function$

