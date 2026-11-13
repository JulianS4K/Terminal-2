-- Migration 20261113030000 · level:secondary-sales · lane:D0 · writes:sub_finder_buy · reads:sub_finder_order,n2s_items,v_s4kcs_orders,v_sub_orders,n2s_autobuy_exec · pre:20261112010000
--
-- SUB FINDER: a CRM-confirmed EVO buy is checked against our own order books first.
--
-- Operator 2026-11-13: "Evo auto buy is only for index 1 or if crm confirms the subs as good
-- to buy", then "Orderbook check on". The CRM's confirmation is POST .../buy -> sub_finder_buy.
-- Until now it bought on whatever order details the caller had sent, so a made-up order with
-- an inflated sale price could spend money. Now it is refused unless the order is in OUR copy
-- of the N2S book or the marketplace order book with the same event, section, row, quantity
-- and sale price; unless N2S's own auto-buy already has the order; and unless one of our order
-- feeds marks the sale finished. Everything else (the key switch, the quoted-cover rule, the
-- manual sub buy path's own ceilings and fresh re-read) is unchanged. No new write path.
--
-- rollback: re-apply sub_finder_buy from 20261112010000.

CREATE OR REPLACE FUNCTION public.sub_finder_buy(
  p_key_id bigint, p_key_label text, p_job_id uuid, p_order_number text, p_listing_id text,
  p_requested_by text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  o     public.sub_finder_order;
  cv    jsonb;
  v_buy bigint;
  v_n   integer;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'buy')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'buying is not enabled for this key');
  END IF;
  SELECT count(*) INTO v_n FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number;
  IF v_n = 0 THEN RETURN jsonb_build_object('error', 'not_found', 'detail', 'no such order in this job'); END IF;
  IF v_n > 1 THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this order number appears more than once in the job');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number FOR UPDATE;
  IF o.buy_id IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy was already requested for this order',
                              'buy_id', o.buy_id);
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) x
   WHERE x->>'market' = 'evo' AND x->>'listing_id' = p_listing_id LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', 'that listing is not an EVO cover this job quoted for this order');
  END IF;
  -- The purchase is decided on OUR copy of the order, not on what the caller sent: it must be
  -- in the N2S book or the marketplace order book with this event, these seats, this quantity
  -- and this sale price.
  IF NOT EXISTS (
       SELECT 1 FROM public.n2s_items n
        WHERE (n.order_number = o.order_number OR n.n2s_order_key = o.order_number)
          AND n.tevo_event_id = o.tevo_event_id
          AND public.seat_section_norm(n.section) = public.seat_section_norm(o.section)
          AND upper(btrim(n.row)) = upper(btrim(o.seat_row)) AND n.qty = o.qty
          AND abs(n.price_per_ticket - o.sold_ea) <= 0.01)
     AND NOT EXISTS (
       SELECT 1 FROM public.v_s4kcs_orders v
        WHERE v.s4k_order_id = o.order_number
          AND v.tevo_event_id = o.tevo_event_id
          AND public.seat_section_norm(v.section) = public.seat_section_norm(o.section)
          AND upper(btrim(v.row)) = upper(btrim(o.seat_row)) AND v.quantity = o.qty
          AND abs(v.price_per_ticket - o.sold_ea) <= 0.01) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this order is not in our copy of the order books with these seats, quantity and sale price; '
                || 'alert us with the order number only');
  END IF;
  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = o.order_number) THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'the Need-to-Sub auto-buy already has this order');
  END IF;
  -- the sale must still be live (about 1.7 s; last, only for a buy that would otherwise go ahead)
  IF EXISTS (SELECT 1 FROM public.v_sub_orders v WHERE v.order_id = o.order_number AND NOT v.is_open) THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this sale is marked fulfilled, cancelled or rejected');
  END IF;
  BEGIN
    v_buy := public.manual_sub_buy_request(
      coalesce(o.site, 'CRM'), o.order_number, o.tevo_event_id, (cv->>'listing_id')::bigint,
      (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, o.sold_ea, o.event_name,
      'crm api key ' || coalesce(p_key_label, p_key_id::text)
        || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
      'sub finder job ' || p_job_id || ': sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
        || '; sub ' || (cv->>'section') || ' row ' || (cv->>'row') || ' x' || (cv->>'buy_qty'));
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy already exists for this sale');
  END;
  UPDATE public.sub_finder_order SET buy_id = v_buy, updated_at = now()
   WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('buy_id', v_buy, 'state', 'requested', 'order_number', o.order_number,
                            'listing_id', cv->>'listing_id', 'qty', (cv->>'buy_qty')::int,
                            'max_price_ea', (cv->>'price_ea')::numeric);
END
$$;
