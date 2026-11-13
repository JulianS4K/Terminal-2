CREATE OR REPLACE FUNCTION public.sub_finder_buy_result_json(b manual_sub_buy)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'buyer',               'sub_finder',
    'buy_ref',             b.market || '-' || b.buy_order_id,
    'bought_on',           b.market,
    'bought_order_number', b.buy_order_id,
    'for_order', jsonb_build_object(
        'order_number', b.sale_order_number,
        'ref',          coalesce(lower(b.sale_site), 'unknown') || '-' || b.sale_order_number,
        'sold_on',      b.sale_site,
        'section',      o.section,
        'row',          o.seat_row,
        'qty',          coalesce(o.qty, b.qty),
        'sold_total_usd', round(b.sold_ea * b.qty, 2),
        'state',        NULL),
    'status', CASE WHEN b.state = 'unknown' THEN 'check_manually'
                   WHEN b.state = 'bought' AND b.outcome = 'confirmed' THEN 'went_through'
                   WHEN b.state IN ('buying', 'bought') THEN 'pending'
                   ELSE 'stopped' END,
    'went_through', b.state = 'bought' AND b.outcome = 'confirmed',
    'phase',        b.state,
    'reasons',      to_jsonb(b.reasons),
    'event', jsonb_build_object('name', b.event_name, 'local_start', ev.occurs_at_local,
                                'start_utc', NULL, 'venue', o.venue,
                                'tevo_event_id', b.tevo_event_id, 'gotickets_event_id', b.gt_event_id),
    'bought', jsonb_build_object('listing_id', b.ticket_group_id::text, 'section', b.bought_section,
                                 'row', b.bought_row, 'qty', b.qty, 'seats', b.seats,
                                 'state', coalesce(b.order_state, b.buy_state)),
    'totals', jsonb_build_object(
        'quoted_usd',  coalesce(b.quote_total_usd, round(b.bought_price_ea * b.qty, 2)),
        'charged_usd', coalesce(b.order_total_usd, b.bought_total_usd),
        'sold_usd',    round(b.sold_ea * b.qty, 2),
        'margin_usd',  round(b.sold_ea * b.qty - coalesce(b.order_total_usd, b.bought_total_usd, b.quote_total_usd,
                                                         b.bought_price_ea * b.qty), 2)),
    'bought_at',  b.created_at,
    'updated_at', b.changed_at)
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT so.section, so.seat_row, so.qty, so.venue FROM public.sub_finder_order so
                      WHERE so.order_number = b.sale_order_number
                      ORDER BY so.updated_at DESC LIMIT 1) o ON true
  LEFT JOIN public.events ev ON ev.id = b.tevo_event_id;
$function$

