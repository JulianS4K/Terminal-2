CREATE OR REPLACE FUNCTION public.sub_finder_lookup(p_order text)
 RETURNS TABLE(rnk integer, book text, site text, tevo_event_id bigint, event_name text, event_date date, venue text, section text, seat_row text, qty integer, sold_ea numeric, status text, is_open boolean, pulled_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH n AS (SELECT CASE WHEN p_order ~ '^\d{1,18}$' THEN p_order::bigint END AS num)
  SELECT 1, 'api', 'GoTickets', ge.tevo_event_id, g.event_name, g.event_time_local::date, g.venue_name,
         g.section, g.row, g.quantity,
         coalesce(g.unit_cost, round(g.total_payout / nullif(g.quantity, 0), 2)),
         s.st, s.st = 'open', g.pulled_at
  FROM n JOIN public.gotickets_sales g ON g.gt_sale_id = n.num
  LEFT JOIN public.gotickets_event ge ON ge.gt_event_id = g.gt_event_id
  CROSS JOIN LATERAL (SELECT CASE
           WHEN g.raw->>'cancelReason' IS NOT NULL THEN CASE WHEN g.raw->>'cancelReason' = 'REJECTED' THEN 'rejected' ELSE 'cancelled' END
           WHEN coalesce(g.fulfilled, false)
             OR g.seller_status IN ('COMPLETED', 'PENDING_TRANSFER_PROOF', 'PENDING_PROOF_OF_PICKUP') THEN 'fulfilled'
           ELSE 'open' END AS st) s
  UNION ALL
  SELECT 1, 'api', 'TickPick', t.tevo_event_id, t.event_name, t.event_date::date, NULL,
         t.section, t.row, t.quantity, t.total,           -- tickpick_orders.total is the per-ticket price
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), t.pulled_at
  FROM public.tickpick_orders t
  LEFT JOIN public.order_status_xref x ON x.source = 'tickpick' AND x.source_status = lower(t.order_status)
  WHERE t.tp_order_id = p_order
  UNION ALL
  SELECT 1, 'api', 'Vivid Seats', v.tevo_event_id, v.event_name, v.event_date::date, NULL,
         v.section, v.row, v.quantity, v.total,           -- vivid_orders.total is the per-ticket price
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), v.pulled_at
  FROM public.vivid_orders v
  LEFT JOIN public.order_status_xref x ON x.source = 'vivid' AND x.source_status = v.status
  WHERE v.vivid_order_id = p_order
  UNION ALL
  SELECT 1, 'api', 'SeatGeek', g.tevo_event_id, g.sg_event_name, g.sg_event_date, g.sg_venue,
         g.sale_section, g.sale_row, g.sale_quantity, g.sale_price,
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), g.pulled_at
  FROM public.seatgeek_orders g
  LEFT JOIN public.order_status_xref x ON x.source = 'seatgeek' AND x.source_status = g.status
  WHERE g.sg_order_id = p_order
  UNION ALL
  SELECT 1, 'api', 'Ticket Evolution', i.event_id, i.event_name, i.occurs_at::date, i.venue_name,
         i.ticket_group_section, i.ticket_group_row, i.quantity, i.price,
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), o.pulled_at
  FROM n JOIN public.evo_orders o ON o.evo_order_id = n.num AND o.seller_brokerage_id = 1768   -- our sales only
  JOIN public.evo_order_items i ON i.evo_order_id = o.evo_order_id
  LEFT JOIN public.order_status_xref x ON x.source = 'evo' AND x.source_status = o.state
  UNION ALL
  SELECT 2, 'n2s', i.marketplace, i.tevo_event_id, i.event_name, i.event_dt::date, i.venue,
         i.section, i.row, i.qty, i.price_per_ticket, 'open', true, i.pulled_at
  FROM public.n2s_items i
  WHERE i.order_number = p_order OR i.n2s_order_key = p_order
  UNION ALL
  SELECT 3, 'marketplace', c.source, c.tevo_event_id, c.event_name, c.event_date, c.venue_name,
         c.section, c.row, c.quantity, c.price_per_ticket,
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), c.pulled_at
  FROM public.v_s4kcs_orders c
  LEFT JOIN public.order_status_xref x ON x.source = 's4kcs' AND x.source_status = c.order_status
  WHERE c.s4k_order_id = p_order;
$function$

