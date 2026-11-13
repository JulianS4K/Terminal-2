CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_request(p_key_id bigint, p_key_label text, p_order_number text, p_listing_id text, p_market text DEFAULT NULL::text, p_requested_by text DEFAULT NULL::text, p_rebate_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  o      public.sub_finder_order;
  cv     jsonb;
  v_gate integer;
  v_id   bigint;
  v_back integer;
  v_sale numeric;
  v_reb  numeric := nullif(round(p_rebate_amount, 2), 0);   -- 0 = no rebate
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'offer')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'offering subs is not enabled for this key');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE key_id = p_key_id AND order_number = p_order_number AND watching
   ORDER BY updated_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'not_found', 'detail', 'no open lookup holds this order; alert us first');
  END IF;
  IF lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' OR p_order_number !~ '^\d{1,18}$' THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'only GoTickets orders can be offered a sub here');
  END IF;
  -- the offer is decided on OUR copy of the order, not on what the caller sent
  IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'n2s', 'marketplace'], false) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this order is not in our copy of the GoTickets order book with these seats; alert us with the order number only');
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
   WHERE x->>'listing_id' = p_listing_id AND x->>'source' = 'native'
     AND (p_market IS NULL OR x->>'market' = lower(btrim(p_market)))
   ORDER BY n LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'that listing is not a cover this lookup quoted for this order');
  END IF;
  v_gate := (cv->>'gate')::int;
  IF v_gate IS NULL OR (v_gate < 3 AND NOT (public.sub_finder_cover_flags(cv) ? 'single_ticket_row_differs')) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'gate 1-2 covers need no offer: the seats are in the same section, same or better row');
  END IF;
  IF v_gate = 6 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'gate 6 covers are results only and are not offered');
  END IF;
  -- The rebate is the CRM's call: we suggest one (sale total - sub total) but never set it.
  -- Rows back (gate 5) need an explicit answer, 0 included; other gates take one if sent.
  v_sale := round(o.sold_ea * o.qty, 2);
  IF v_gate = 5 AND p_rebate_amount IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this sub moves the customer back: send rebate_amount (0 for none)',
      'rebate_suggested', greatest((cv->>'profit')::numeric, 0));
  END IF;
  IF v_reb IS NOT NULL AND (v_reb < 0 OR v_sale IS NULL OR v_reb > v_sale) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'rebate_amount must be between 0 and the sale total', 'sale_total', v_sale);
  END IF;
  v_back := public.seat_row_rank(cv->>'row') - public.seat_row_rank(o.seat_row);
  BEGIN
    INSERT INTO public.sub_finder_gt_offer
      (job_id, idx, key_id, requested_by, order_number, gt_order_id, gate, market, listing_id, section, seat_row,
       qty, buy_qty, price_ea, order_total, sub_total, rebate_amount, notes)
    VALUES (o.job_id, o.idx, p_key_id,
            'crm api key ' || coalesce(p_key_label, p_key_id::text) || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
            o.order_number, o.order_number::bigint, v_gate, cv->>'market', cv->>'listing_id', cv->>'section', cv->>'row',
            o.qty, (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, round(o.sold_ea * o.qty, 2), (cv->>'total')::numeric,
            v_reb,                                                        -- the amount the CRM gave
            CASE WHEN v_gate = 5
                 THEN 'Replacement seats in the same area, ' || v_back || ' row' || CASE WHEN v_back = 1 THEN '' ELSE 's' END
                      || ' further back than the original row ' || o.seat_row
                      || CASE WHEN v_reb IS NOT NULL THEN ', with a rebate.' ELSE '.' END
                 ELSE 'Comparable replacement seats in the same area, in the same row or closer than the original section '
                      || o.section || ' row ' || o.seat_row || '.' END)
    RETURNING offer_id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'an offer already exists for this order');
  END;
  UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('offer_id', v_id, 'state', 'requested', 'gate', v_gate,
                            'section', cv->>'section', 'row', cv->>'row',
                            'rebate', v_reb);
END
$function$

