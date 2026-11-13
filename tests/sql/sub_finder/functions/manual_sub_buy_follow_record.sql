CREATE OR REPLACE FUNCTION public.manual_sub_buy_follow_record(p_buy_id bigint, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_seller  text := lower(nullif(btrim(p_patch->>'seller_state'), ''));
  v_order   text := lower(nullif(btrim(p_patch->>'order_state'), ''));
  v_outcome text;
BEGIN
  v_outcome := CASE
    WHEN 'rejected' IN (v_seller, v_order) THEN 'rejected'
    WHEN v_seller IN ('canceled', 'cancelled') OR v_order IN ('canceled', 'cancelled') THEN 'canceled'
    WHEN v_seller IN ('accepted', 'completed') THEN 'confirmed'
    ELSE 'pending' END;
  UPDATE public.manual_sub_buy
     SET outcome          = v_outcome,
         seller_state     = COALESCE(v_seller, seller_state),
         order_state      = COALESCE(v_order, order_state),
         order_total_usd  = COALESCE((p_patch->>'order_total_usd')::numeric, order_total_usd),
         bought_section   = COALESCE(nullif(p_patch->>'bought_section', ''), bought_section),
         bought_row       = COALESCE(nullif(p_patch->>'bought_row', ''), bought_row),
         seats            = CASE WHEN jsonb_typeof(p_patch->'seats') = 'array' AND jsonb_array_length(p_patch->'seats') > 0
                                 THEN p_patch->'seats' ELSE seats END,
         rejection_reason = COALESCE(nullif(p_patch->>'rejection_reason', ''), rejection_reason),
         final_at         = CASE WHEN v_outcome = 'pending' THEN NULL ELSE now() END,
         -- a rejected or canceled order bought nothing: release the sale and the spend
         state            = CASE WHEN v_outcome IN ('rejected', 'canceled') THEN 'stopped' ELSE state END,
         reasons          = CASE WHEN v_outcome = 'rejected' THEN reasons || 'seller_rejected'::text
                                 WHEN v_outcome = 'canceled' THEN reasons || 'order_canceled'::text
                                 ELSE reasons END,
         updated_at       = CASE WHEN v_outcome IN ('rejected', 'canceled') THEN now() ELSE updated_at END
   WHERE buy_id = p_buy_id AND state = 'bought' AND final_at IS NULL;
  IF NOT FOUND THEN RETURN 'not_open'; END IF;
  RETURN v_outcome;
END $function$

