CREATE OR REPLACE FUNCTION public.sub_finder_release_stopped()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config;
  r       record;
  v_n     integer := 0;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.buy_fallback_enabled THEN RETURN 0; END IF;
  FOR r IN
    SELECT o.job_id, o.idx, o.buy_id
      FROM public.sub_finder_order o
      JOIN public.manual_sub_buy b ON b.buy_id = o.buy_id
     WHERE o.watching AND b.state = 'stopped' AND public.sub_finder_stop_is_listing(b.reasons)
       -- an accepted GoTickets offer's buy is released by its own rule (sub_finder_refresh, step 4)
       AND NOT EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g WHERE g.buy_id = o.buy_id)
       AND (SELECT count(*) FROM public.manual_sub_buy s
             WHERE s.sale_order_number = o.order_number AND s.state = 'stopped'
               AND (s.updated_at AT TIME ZONE 'America/New_York')::date = v_today) < c.buy_fallback_max
     ORDER BY o.job_id, o.idx LIMIT 50
  LOOP
    UPDATE public.sub_finder_order
       SET buy_id = NULL, action = CASE WHEN action = 'auto_bought' THEN 'review' ELSE action END,
           rematch = true, updated_at = now()
     WHERE job_id = r.job_id AND idx = r.idx AND buy_id = r.buy_id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$function$

