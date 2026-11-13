CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_claim()
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
  UPDATE public.sub_finder_gt_offer
     SET state = 'unknown', reasons = ARRAY['offer_unknown'], error = 'worker stopped mid-offer', updated_at = now()
   WHERE state = 'sending' AND lease_until < now();
  IF NOT c.enabled OR NOT c.gt_offer_enabled THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.sub_finder_gt_offer
   WHERE state = 'requested' AND (lease_until IS NULL OR lease_until < now())
   ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.sub_finder_gt_offer
     SET lease_token = gen_random_uuid(), lease_until = now() + make_interval(secs => c.gt_offer_lease_s), updated_at = now()
   WHERE offer_id = r.offer_id RETURNING * INTO r;
  RETURN to_jsonb(r);
END
$function$

