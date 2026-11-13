CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_confirmed(p_key_id bigint, p_key_label text, p_order_number text, p_listing_id text, p_market text, p_requested_by text, p_rebate_amount numeric, p_confirm boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_flags jsonb;
BEGIN
  -- offering IS the careful path for a single ticket in another row, so that flag needs no confirm here
  SELECT public.sub_finder_cover_flags(c.x) - 'single_ticket_row_differs' INTO v_flags
    FROM (SELECT o.covers FROM public.sub_finder_order o
           WHERE o.key_id = p_key_id AND o.order_number = p_order_number AND o.watching
           ORDER BY o.updated_at DESC LIMIT 1) w,
         jsonb_array_elements(w.covers) WITH ORDINALITY c(x, n)
   WHERE c.x->>'listing_id' = p_listing_id AND c.x->>'source' = 'native'
     AND (p_market IS NULL OR c.x->>'market' = lower(btrim(p_market)))
   ORDER BY c.n LIMIT 1;
  IF NOT coalesce(p_confirm, false) AND jsonb_array_length(coalesce(v_flags, '[]'::jsonb)) > 0 THEN
    RETURN jsonb_build_object('error', 'confirm_needed', 'flags', v_flags,
      'detail', 'this cover is flagged: send "confirm": true to offer it anyway');
  END IF;
  RETURN public.sub_finder_gt_offer_request(p_key_id, p_key_label, p_order_number, p_listing_id,
                                            p_market, p_requested_by, p_rebate_amount);
END
$function$

