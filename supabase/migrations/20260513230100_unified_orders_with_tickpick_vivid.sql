-- Extend public.unified_orders to UNION ALL tickpick_orders + vivid_orders.
-- The existing 3-source view (evo / seatgeek / seatdata) stays unchanged in
-- shape — same column list, same semantics. New rows for tickpick + vivid
-- carry tevo_event_id (nullable, populated by future xref logic) and
-- canonical_status from the order_status_xref rows the prior migration added.
--
-- This is a CREATE OR REPLACE — no downtime, no orphan dependent objects.

CREATE OR REPLACE VIEW public.unified_orders AS
SELECT 'evo'::text AS source,
    o.evo_order_id::text AS source_order_id,
    ( SELECT min(i.event_id) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS tevo_event_id,
    NULL::text AS sg_event_id,
    o.state AS source_status,
    xref.canonical_status,
    xref.is_terminal,
    xref.is_sale_succeeded,
    o.type AS source_type,
    ( SELECT sum(i.price * i.quantity::numeric) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS gross_value,
    ( SELECT sum(i.quantity) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS quantity,
    o.buyer_name,
    o.seller_name,
    o.client_name,
    o.evo_created_at AS created_at,
    o.evo_updated_at AS updated_at,
    o.last_seen_at
FROM public.evo_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'evo'::text AND xref.source_status = o.state

UNION ALL
SELECT 'seatgeek'::text AS source,
    o.sg_order_id AS source_order_id,
    o.tevo_event_id,
    o.sg_event_id::text AS sg_event_id,
    o.status AS source_status,
    xref.canonical_status,
    xref.is_terminal,
    xref.is_sale_succeeded,
    NULL::text AS source_type,
    o.payment_total AS gross_value,
    o.sale_quantity AS quantity,
    NULL::text AS buyer_name,
    NULL::text AS seller_name,
    NULL::text AS client_name,
    o.created_at_sg AS created_at,
    o.last_status_at AS updated_at,
    o.last_status_at AS last_seen_at
FROM public.seatgeek_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'seatgeek'::text AND xref.source_status = o.status

UNION ALL
SELECT 'seatdata'::text AS source,
    s.content_hash AS source_order_id,
    s.tevo_event_id,
    NULL::text AS sg_event_id,
    'sold'::text AS source_status,
    'fulfilled'::text AS canonical_status,
    true AS is_terminal,
    true AS is_sale_succeeded,
    NULL::text AS source_type,
    s.price * COALESCE(NULLIF(s.quantity, 0), 1)::numeric AS gross_value,
    s.quantity,
    NULL::text AS buyer_name,
    NULL::text AS seller_name,
    NULL::text AS client_name,
    s.sale_timestamp AS created_at,
    s.sale_timestamp AS updated_at,
    s.pulled_at AS last_seen_at
FROM public.seatdata_sales_snapshots s

UNION ALL
SELECT 'tickpick'::text AS source,
    o.tp_order_id AS source_order_id,
    o.tevo_event_id,
    NULL::text AS sg_event_id,
    o.status AS source_status,
    xref.canonical_status,
    xref.is_terminal,
    xref.is_sale_succeeded,
    NULL::text AS source_type,
    o.total AS gross_value,
    o.quantity::bigint AS quantity,
    NULL::text AS buyer_name,
    NULL::text AS seller_name,
    NULL::text AS client_name,
    COALESCE(o.ordered_at, o.pulled_at) AS created_at,
    o.last_seen_at AS updated_at,
    o.last_seen_at
FROM public.tickpick_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'tickpick'::text AND xref.source_status = o.status

UNION ALL
SELECT 'vivid'::text AS source,
    o.vivid_order_id AS source_order_id,
    o.tevo_event_id,
    NULL::text AS sg_event_id,
    o.status AS source_status,
    xref.canonical_status,
    xref.is_terminal,
    xref.is_sale_succeeded,
    NULL::text AS source_type,
    o.total AS gross_value,
    o.quantity::bigint AS quantity,
    NULLIF(concat_ws(' ', o.first_name, o.last_name), '') AS buyer_name,
    NULL::text AS seller_name,
    NULL::text AS client_name,
    COALESCE(o.ordered_at, o.pulled_at) AS created_at,
    o.last_seen_at AS updated_at,
    o.last_seen_at
FROM public.vivid_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'vivid'::text AND xref.source_status = o.status;
