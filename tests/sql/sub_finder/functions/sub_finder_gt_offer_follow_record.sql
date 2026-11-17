CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_follow_record(p_offer_id bigint, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r        public.sub_finder_gt_offer;
  v_status text := upper(nullif(btrim(p_patch->>'gt_status'), ''));
  v_closed text;
BEGIN
  IF v_status IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.sub_finder_gt_offer WHERE offer_id = p_offer_id AND state = 'sent' FOR UPDATE;
  IF NOT FOUND OR r.gt_status IS NOT DISTINCT FROM v_status THEN RETURN v_status; END IF;
  UPDATE public.sub_finder_gt_offer
     SET gt_status = v_status, denial_reason = p_patch->>'denial_reason',
         final_at = CASE WHEN v_status IN ('ACCEPTED', 'DENIED', 'CANCELLED') THEN now() END,
         live = (v_status NOT IN ('DENIED', 'CANCELLED')),
         updated_at = now()
   WHERE offer_id = p_offer_id;
  -- The offer ended without a sub: check the sale before the order is polled again. The worker's
  -- fresh read of the sale comes first; our own copy of the order book is checked either way
  -- (it is all there is when the read failed). A sale that is over closes the lookup.
  IF v_status IN ('DENIED', 'CANCELLED') THEN
    v_closed := coalesce(
      CASE WHEN p_patch->>'sale_closed' IN ('cancelled', 'fulfilled') THEN p_patch->>'sale_closed' END,
      public.sub_finder_order_closed(r.order_number, 'GoTickets'));
  END IF;
  UPDATE public.sub_finder_order
     SET updated_at = now(),
         feed_checked_at = CASE WHEN v_status IN ('DENIED', 'CANCELLED') THEN now() ELSE feed_checked_at END,
         watching      = CASE WHEN v_closed IS NOT NULL THEN false ELSE watching END,
         closed_reason = CASE WHEN v_closed IS NOT NULL AND watching THEN 'order_' || v_closed ELSE closed_reason END,
         closed_at     = CASE WHEN v_closed IS NOT NULL AND watching THEN now() ELSE closed_at END
   WHERE job_id = r.job_id AND idx = r.idx;
  IF v_status = 'ACCEPTED' THEN PERFORM public.sub_finder_gt_offer_buy(p_offer_id); END IF;
  RETURN v_status;
END
$function$

