CREATE OR REPLACE FUNCTION public.sub_finder_buy_confirmed(p_key_id bigint, p_key_label text, p_job_id uuid, p_order_number text, p_listing_id text, p_requested_by text, p_confirm boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_flags jsonb;
BEGIN
  SELECT public.sub_finder_cover_flags(x) INTO v_flags
    FROM public.sub_finder_order o, jsonb_array_elements(o.covers) x
   WHERE o.job_id = p_job_id AND o.key_id = p_key_id AND o.order_number = p_order_number
     AND public.sub_finder_market_buyable(x->>'market') AND x->>'listing_id' = p_listing_id
   ORDER BY (x->>'market' = 'evo') DESC                -- the same cover sub_finder_buy will take
   LIMIT 1;
  IF NOT coalesce(p_confirm, false) AND jsonb_array_length(coalesce(v_flags, '[]'::jsonb)) > 0 THEN
    RETURN jsonb_build_object('error', 'confirm_needed', 'flags', v_flags,
      'detail', 'this cover is flagged: send "confirm": true to buy it anyway');
  END IF;
  RETURN public.sub_finder_buy(p_key_id, p_key_label, p_job_id, p_order_number, p_listing_id, p_requested_by);
END
$function$

