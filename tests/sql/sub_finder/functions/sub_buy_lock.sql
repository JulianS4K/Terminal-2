CREATE OR REPLACE FUNCTION public.sub_buy_lock()
 RETURNS void
 LANGUAGE sql
AS $function$ SELECT pg_advisory_xact_lock(20261113430000) $function$

