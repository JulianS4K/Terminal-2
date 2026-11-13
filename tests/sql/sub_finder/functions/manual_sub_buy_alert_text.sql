CREATE OR REPLACE FUNCTION public.manual_sub_buy_alert_text(b manual_sub_buy, p_kind text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'subject', CASE p_kind
        WHEN 'bought'  THEN format('Sub buy PLACED: %s order %s for %s sale %s ($%s)',
                                   t.mkt, b.buy_order_id, b.sale_site, b.sale_order_number, t.total)
        WHEN 'unknown' THEN format('Sub buy NEEDS A CHECK: %s sale %s, %s did not answer clearly',
                                   b.sale_site, b.sale_order_number, t.mkt)
        ELSE format('Sub buy %s: %s order %s for %s sale %s',
                    upper(CASE b.outcome WHEN 'canceled' THEN 'cancelled' ELSE b.outcome END), t.mkt,
                    coalesce(b.buy_order_id, 'n/a'), b.sale_site, b.sale_order_number) END,
    'text', format(E'%s\n\n'
                || E'Buy id %s, requested by %s\n'
                || E'%s order: %s (listing %s)\n'
                || E'Sale it covers: order %s on %s\n\n'
                || E'Event: %s\nSeats: %s\nQty %s at $%s each, total $%s\n'
                || E'Sold at $%s each, total $%s: %s\n%s',
           CASE p_kind
             WHEN 'bought'  THEN t.mkt || ' took the order. Money is committed; waiting for the seller to confirm.'
             WHEN 'unknown' THEN t.mkt || ' did not answer clearly, so we do not know whether this was bought. '
                              || 'Check it in ' || t.mkt || '. No other buy goes out until this is cleared.'
             ELSE CASE b.outcome
                    WHEN 'confirmed' THEN 'The seller confirmed. The sale is covered.'
                    WHEN 'rejected'  THEN 'The seller REJECTED the order. The sale is NOT covered; pick another sub.'
                    ELSE 'The order was CANCELLED. The sale is NOT covered; pick another sub.' END END,
           b.buy_id, b.requested_by,
           t.mkt, coalesce(b.buy_order_id, 'none recorded'), b.ticket_group_id,
           b.sale_order_number, b.sale_site,
           coalesce(b.event_name, 'event ' || coalesce(b.tevo_event_id::text, '?')),
           coalesce(nullif(concat_ws(' row ', b.bought_section, b.bought_row), ''), 'not known yet'),
           b.qty, coalesce(b.bought_price_ea, b.max_price_ea), t.total,
           coalesce(b.sold_ea::text, '?'), coalesce((b.sold_ea * b.qty)::text, '?'),
           CASE WHEN b.sold_ea IS NULL THEN 'profit not known'
                WHEN b.sold_ea * b.qty - t.total >= 0 THEN 'profit $' || round(b.sold_ea * b.qty - t.total, 2)
                ELSE 'LOSS $' || round(t.total - b.sold_ea * b.qty, 2) END,
           CASE WHEN b.rejection_reason IS NOT NULL THEN 'Reason given: ' || b.rejection_reason
                WHEN b.error IS NOT NULL AND p_kind = 'unknown' THEN 'Error: ' || left(b.error, 300)
                ELSE '' END))
  FROM (SELECT round(coalesce(b.order_total_usd, b.bought_total_usd,
                              b.qty * coalesce(b.bought_price_ea, b.max_price_ea)), 2) AS total,
               CASE b.market WHEN 'gotickets' THEN 'GoTickets' ELSE 'EVO' END AS mkt) t
$function$

