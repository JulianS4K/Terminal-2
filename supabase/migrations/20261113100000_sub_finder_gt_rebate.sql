-- Migration 20261113100000 · level:secondary-sales · lane:D0 · writes:sub_finder_gt_offer_request,sub_finder_offer_json · reads:sub_finder_order,sub_finder_gt_offer · pre:20261113060000
--
-- SUB FINDER, GoTickets offer: the rebate amount comes from the CRM.
--
-- Operator 2026-11-13: "For go tickets rebate ask CRM for amount". Until now a gate 5 offer
-- (rows back) carried a rebate we worked out ourselves: sale total - sub total. Now:
--   * the order's `sub_offer` shows `rebate_needed` (true for gate 5) and `rebate_suggested`
--     (sale total - sub total, never below 0) — a suggestion only;
--   * the CRM's yes (POST /orders/{n}/offer-sub) carries `rebate_amount`. Gate 5 is refused
--     without one (0 is a valid answer: no rebate). Gates 3-4 take one if the CRM sends it.
--     It must be between 0 and the sale total;
--   * what was offered is `sub_offer.rebate`.
-- The function gains a 7th argument, so the 6-argument version is dropped.
--
-- rollback: DROP FUNCTION public.sub_finder_gt_offer_request(bigint, text, text, text, text, text, numeric);
--           re-apply sub_finder_gt_offer_request and sub_finder_offer_json from 20261113060000.

DROP FUNCTION IF EXISTS public.sub_finder_gt_offer_request(bigint, text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_request(
  p_key_id bigint, p_key_label text, p_order_number text, p_listing_id text,
  p_market text DEFAULT NULL, p_requested_by text DEFAULT NULL, p_rebate_amount numeric DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
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
  IF v_gate IS NULL OR v_gate < 3 THEN
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
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_offer_json(o public.sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' THEN NULL
    WHEN r.offer_id IS NULL AND coalesce((o.best->>'gate')::int, 0) < 3 THEN NULL
    ELSE jsonb_build_object(
      'via', 'gotickets',
      -- true: tell us yes with POST /orders/{n}/offer-sub and this listing_id
      'ask_crm', r.offer_id IS NULL AND o.watching AND o.order_source IN ('api', 'n2s', 'marketplace')
                 AND (o.best->>'gate')::int IN (3, 4, 5),
      'results_only', r.offer_id IS NULL AND (o.best->>'gate')::int = 6,
      'gate', coalesce(r.gate, (o.best->>'gate')::int),
      'market', coalesce(r.market, o.best->>'market'),
      'listing_id', coalesce(r.listing_id, o.best->>'listing_id'),
      'section', coalesce(r.section, o.best->>'section'), 'row', coalesce(r.seat_row, o.best->>'row'),
      -- the rebate is yours to set: `rebate` is what was offered; before that, `rebate_needed`
      -- says an amount must come with the yes (rows back) and `rebate_suggested` is sale - sub
      'rebate', r.rebate_amount,
      'rebate_needed', r.offer_id IS NULL AND (o.best->>'gate')::int = 5,
      'rebate_suggested', CASE WHEN r.offer_id IS NULL AND (o.best->>'gate')::int IN (3, 4, 5)
                               THEN greatest((o.best->>'profit')::numeric, 0) END,
      'request', CASE WHEN r.offer_id IS NOT NULL THEN jsonb_build_object(
                   'offer_id', r.offer_id, 'state', r.state, 'reasons', r.reasons,
                   'gotickets_request_id', r.gt_request_id, 'status', r.gt_status,
                   'denial_reason', r.denial_reason, 'status_checked_at', r.status_checked_at,
                   -- after ACCEPTED: 'buy_requested' (see the order's `buy`) or why we did not buy
                   'buy', CASE WHEN r.buy_id IS NOT NULL THEN 'buy_requested' ELSE r.buy_note END,
                   'final_at', r.final_at) END)
  END
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT g.* FROM public.sub_finder_gt_offer g
                      WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                      ORDER BY g.live DESC, g.offer_id DESC LIMIT 1) r ON true;
$$;

REVOKE ALL ON FUNCTION public.sub_finder_gt_offer_request(bigint, text, text, text, text, text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_gt_offer_request(bigint, text, text, text, text, text, numeric) TO service_role;
