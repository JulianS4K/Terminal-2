CREATE OR REPLACE FUNCTION public.sub_finder_audit_log(p_account_id bigint, p_key_id bigint, p_key_label text, p_action text, p_order_number text, p_listing_id text, p_source_ip text, p_requested_by text, p_idem_key text, p_http_status integer, p_response jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ok    boolean := p_http_status BETWEEN 200 AND 299;
  v_buy   bigint := CASE WHEN v_ok THEN nullif(p_response->>'buy_id', '')::bigint END;
  v_offer bigint := CASE WHEN v_ok THEN nullif(p_response->>'offer_id', '')::bigint END;
BEGIN
  INSERT INTO public.sub_finder_audit
    (account_id, key_id, key_label, action, order_number, listing_id, market, amount_usd, rebate_usd,
     source_ip, requested_by, idem_key, http_status, outcome, buy_id, offer_id, response)
  SELECT p_account_id, p_key_id, p_key_label, p_action, p_order_number, p_listing_id,
         coalesce(b.market, g.market, p_response->>'market'),
         coalesce(round(b.max_price_ea * b.qty, 2), g.sub_total),
         g.rebate_amount,
         p_source_ip, nullif(btrim(p_requested_by), ''), nullif(btrim(p_idem_key), ''), p_http_status,
         coalesce(p_response->>'error', p_response->>'state', CASE WHEN v_ok THEN 'saved' ELSE 'refused' END),
         v_buy, v_offer, CASE WHEN v_ok THEN p_response END
    FROM (SELECT 1) one
    LEFT JOIN public.manual_sub_buy b ON b.buy_id = v_buy
    LEFT JOIN public.sub_finder_gt_offer g ON g.offer_id = v_offer
  ON CONFLICT DO NOTHING;      -- a second accepted call under one Idempotency-Key: the first row stands
END
$function$

