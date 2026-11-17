CREATE OR REPLACE FUNCTION public.sub_finder_offer_gone(g sub_finder_gt_offer, p_event bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN g.buy_note = 'offered_seats_gone' THEN true
    WHEN g.gt_status IS DISTINCT FROM 'ACCEPTED' OR p_event IS NULL THEN NULL
    WHEN g.market = 'evo' THEN
      CASE WHEN EXISTS (SELECT 1 FROM public.n2s_evo_current x WHERE x.event_id = p_event
                           AND x.tevo_ticket_group_id::text = g.listing_id) THEN false
           WHEN EXISTS (SELECT 1 FROM public.n2s_evo_current x WHERE x.event_id = p_event
                           AND x.pulled_at > g.final_at) THEN true END
    WHEN g.market = 'gotickets' THEN
      CASE WHEN EXISTS (SELECT 1 FROM public.n2s_gt_current x WHERE x.tevo_event_id = p_event
                           AND x.gt_listing_id::text = g.listing_id) THEN false
           WHEN EXISTS (SELECT 1 FROM public.n2s_gt_current x WHERE x.tevo_event_id = p_event
                           AND x.pulled_at > g.final_at) THEN true END
    WHEN g.market = 'seatgeek' THEN
      CASE WHEN EXISTS (SELECT 1 FROM public.n2s_sg_current x WHERE x.tevo_event_id = p_event
                           AND x.sglid::text = g.listing_id) THEN false
           WHEN EXISTS (SELECT 1 FROM public.n2s_sg_current x WHERE x.tevo_event_id = p_event
                           AND x.pulled_at > g.final_at) THEN true END
  END;
$function$

