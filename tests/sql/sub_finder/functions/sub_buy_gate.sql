CREATE OR REPLACE FUNCTION public.sub_buy_gate(p_market text, p_total_usd numeric)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  k public.sub_buy_control%ROWTYPE;
BEGIN
  PERFORM public.sub_buy_lock();
  SELECT * INTO k FROM public.sub_buy_control WHERE id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF k.enforce AND k.stop THEN RETURN 'shared_stop'; END IF;
  IF lower(p_market) IN ('evo', 'tevo') AND k.evo_inflight_max IS NOT NULL
     AND public.sub_buy_evo_inflight() >= k.evo_inflight_max THEN
    RETURN 'evo_inflight_full';
  END IF;
  -- a buy with no known total cannot be shown to fit under the ceiling
  IF k.enforce AND k.daily_ceiling_usd IS NOT NULL
     AND (p_total_usd IS NULL OR public.sub_buy_spent_today() + p_total_usd > k.daily_ceiling_usd) THEN
    RETURN 'over_shared_ceiling';
  END IF;
  RETURN NULL;
END
$function$

