CREATE OR REPLACE FUNCTION public.manual_sub_buy_follow_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  b public.manual_sub_buy%ROWTYPE;
BEGIN
  SELECT * INTO b FROM public.manual_sub_buy
   WHERE state = 'bought' AND final_at IS NULL AND buy_order_id ~ '^\d+$'
     AND created_at > now() - interval '7 days'
     AND (status_checked_at IS NULL OR status_checked_at < now() - CASE
            WHEN status_checks < 20 THEN interval '30 seconds'
            WHEN status_checks < 60 THEN interval '5 minutes'
            ELSE interval '30 minutes' END)
   ORDER BY status_checked_at NULLS FIRST, buy_id
   LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.manual_sub_buy
     SET status_checked_at = now(), status_checks = status_checks + 1,
         outcome = CASE WHEN outcome = 'none' THEN 'pending' ELSE outcome END
   WHERE buy_id = b.buy_id;
  RETURN jsonb_build_object('buy_id', b.buy_id, 'buy_order_id', b.buy_order_id, 'market', b.market);
END $function$

