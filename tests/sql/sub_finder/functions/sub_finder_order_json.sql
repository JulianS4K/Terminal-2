CREATE OR REPLACE FUNCTION public.sub_finder_order_json(o sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'job_id', o.job_id, 'order_number', o.order_number, 'site', o.site,
    'tevo_event_id', o.tevo_event_id, 'event_name', o.event_name, 'event_date', o.event_date, 'venue', o.venue,
    'section', o.section, 'row', o.seat_row, 'qty', o.qty, 'sold_ea', o.sold_ea,
    'order_source', o.order_source, 'state', o.state,
    -- free text the CRM wrote on this order (POST /orders/{n}/notes, or `notes` with the alert)
    'notes', o.crm_notes,
    -- the last decision read from your N2S feed for this order, and what carrying it out answered
    'feed_decision', (SELECT jsonb_build_object(
                         'decision', d.decision, 'listing_id', d.listing_id, 'decided_at', d.decided_at,
                         'decided_by', d.decided_by, 'outcome', d.outcome,
                         'detail', d.result->>'detail', 'flags', d.result->'flags',
                         'acted_at', to_char(d.acted_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                        FROM public.sub_finder_feed_decision d
                       WHERE d.order_number = o.order_number AND d.key_id = o.key_id
                       ORDER BY d.acted_at DESC LIMIT 1),
    'notes_at', to_char(o.crm_notes_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    -- what to do with the answer, and why it was not bought automatically
    -- once a GoTickets customer has accepted the sub there is nobody left to ask: while the offered
    -- seats are still there, 'offer' reads 'buy_manually' until they are bought. If they are gone
    -- the action is the new match's own (see sub_offer.accepted_next / new_best)
    'action', CASE WHEN o.action = 'offer' AND o.buy_id IS NULL
                        AND EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g
                                     WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                                       AND g.live AND g.gt_status = 'ACCEPTED'
                                       AND NOT coalesce(public.sub_finder_offer_gone(g, o.tevo_event_id), false))
                   THEN 'buy_manually' ELSE o.action END,
    'auto_buy_note', o.auto_buy_note,
    -- GoTickets orders only: the sub we would offer the customer, and how that offer stands
    'sub_offer', public.sub_finder_offer_json(o),
    'best', o.best, 'covers', o.covers,
    'markets_searched', CASE WHEN o.state IN ('cover', 'no_cover')
                             THEN to_jsonb(ARRAY['evo', 'gotickets', 'seatgeek']
                                           || CASE WHEN o.td_state = 'searched' THEN ARRAY['ticketsdata']
                                                   ELSE ARRAY[]::text[] END) END,
    'ticketsdata', o.td_state,
    'watching', o.watching, 'refreshed_at', o.refreshed_at, 'closed_reason', o.closed_reason,
    'buy', (SELECT jsonb_build_object(
                     'buy_id', b.buy_id, 'request_state', b.state, 'reasons', b.reasons,
                     'market', b.market, 'order_id', b.buy_order_id,
                     'evo_order_id', CASE WHEN b.market = 'evo' THEN b.buy_order_id END, 'outcome', b.outcome,
                     'seller_state', b.seller_state, 'order_state', b.order_state,
                     'rejection_reason', b.rejection_reason,
                     'qty', b.qty, 'price_ea', b.bought_price_ea,
                     'total', coalesce(b.order_total_usd, b.bought_total_usd),
                     -- what the buy really made or lost once EVO's charge (tax included) is known, and
                     -- the gate that makes it: 1 Index = a profit, 2 S4KTrading = tax or price turned it into a loss
                     'profit_actual', round(o.sold_ea * o.qty - b.order_total_usd, 2),
                     'gate_actual', CASE WHEN b.order_total_usd IS NULL OR o.sold_ea IS NULL THEN NULL
                                         WHEN o.sold_ea * o.qty - b.order_total_usd > 0 THEN 1 ELSE 2 END,
                     'label_actual', CASE WHEN b.order_total_usd IS NULL OR o.sold_ea IS NULL THEN NULL
                                          WHEN o.sold_ea * o.qty - b.order_total_usd > 0 THEN 'Index' ELSE 'S4KTrading' END,
                     'section', b.bought_section, 'row', b.bought_row, 'seats', b.seats,
                     'status_checked_at', b.status_checked_at, 'final_at', b.final_at)
            FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id),
    'last_stopped_buy', (SELECT jsonb_build_object('buy_id', b.buy_id, 'market', b.market,
                                                    'listing_id', b.ticket_group_id::text, 'reasons', b.reasons,
                                                    'at', to_char(b.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                           FROM public.manual_sub_buy b
                          WHERE b.sale_order_number = o.order_number AND b.state = 'stopped'
                          ORDER BY b.updated_at DESC, b.buy_id DESC LIMIT 1),
    'updated_at', to_char(o.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
$function$

