CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_record(p_offer_id bigint, p_token uuid, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r       public.sub_finder_gt_offer;
  v_state text := p_patch->>'state';
BEGIN
  IF v_state IS NULL OR v_state NOT IN ('sending', 'sent', 'stopped', 'unknown') THEN
    RAISE EXCEPTION 'sub_finder_gt_offer_record: bad state %', v_state;
  END IF;
  UPDATE public.sub_finder_gt_offer
     SET state = v_state,
         live = (v_state <> 'stopped'),
         reasons = CASE WHEN p_patch ? 'reasons'
                        THEN ARRAY(SELECT jsonb_array_elements_text(p_patch->'reasons')) ELSE reasons END,
         error = coalesce(p_patch->>'error', error),
         gt_request_id = coalesce((p_patch->>'gt_request_id')::bigint, gt_request_id),
         gt_status = coalesce(p_patch->>'gt_status', gt_status),
         final_at = CASE WHEN v_state = 'stopped' THEN now() ELSE final_at END,
         updated_at = now()
   WHERE offer_id = p_offer_id AND lease_token = p_token AND lease_until > now()
     AND state IN ('requested', 'sending')
  RETURNING * INTO r;
  IF NOT FOUND THEN RETURN 'lease_lost'; END IF;
  UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = r.job_id AND idx = r.idx;
  RETURN v_state;
END
$function$

