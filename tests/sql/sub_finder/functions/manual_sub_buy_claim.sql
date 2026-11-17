CREATE OR REPLACE FUNCTION public.manual_sub_buy_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- a worker that does not say it can run N2S rows is never handed one (20261113440000)
  RETURN public.manual_sub_buy_claim_for('{}'::text[]);
END $function$

