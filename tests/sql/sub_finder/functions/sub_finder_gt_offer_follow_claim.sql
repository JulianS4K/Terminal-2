CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_follow_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c public.sub_finder_config;
  r public.sub_finder_gt_offer;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  SELECT * INTO r FROM public.sub_finder_gt_offer
   WHERE state = 'sent' AND final_at IS NULL AND gt_request_id IS NOT NULL
     AND (status_checked_at IS NULL OR status_checked_at < now() - c.gt_offer_recheck)
   ORDER BY status_checked_at NULLS FIRST, offer_id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.sub_finder_gt_offer SET status_checked_at = now(), status_checks = status_checks + 1
   WHERE offer_id = r.offer_id;
  RETURN jsonb_build_object('offer_id', r.offer_id, 'gt_order_id', r.gt_order_id, 'gt_request_id', r.gt_request_id);
END
$function$

