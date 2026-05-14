-- Extend public.unified_orders to surface event_name + event_date_local
-- natively per source — removes the hard dependency on tevo_event_id
-- being resolved.
--
-- The 2026-05-14 audit showed all 400 seatgeek_orders rows have
-- tevo_event_id = NULL, so the dashboard's Python-side JOIN to
-- v_event_base never matched and SG rows displayed with a blank
-- event_date. Same risk applies to tickpick + vivid as their crons
-- start writing.
--
-- Each source already has its own native event_name + event_date:
--   evo       : evo_order_items.event_name, .occurs_at
--   seatgeek  : seatgeek_orders.sg_event_name, .sg_event_date + .sg_event_time
--   tickpick  : tickpick_orders.event_name, .event_date
--   vivid     : vivid_orders.event_name, .event_date
--   seatdata  : no native event info — only tevo_event_id; consumer must
--               fall back to v_event_base join for event_name
--
-- The dashboard's Python code prefers these new columns; falls back to
-- v_event_base for seatdata + any source with NULL native event_name.

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
    o.last_seen_at,
    -- NATIVE event info (pulled from items[0])
    ( SELECT i.event_name FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id ORDER BY i.evo_item_id LIMIT 1) AS event_name,
    ( SELECT i.occurs_at  FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id ORDER BY i.evo_item_id LIMIT 1) AS event_date
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
    o.last_status_at AS last_seen_at,
    o.sg_event_name AS event_name,
    -- Combine sg_event_date + sg_event_time into a single timestamp. Both
    -- are populated for every row; safe with COALESCE on time.
    CASE
      WHEN o.sg_event_date IS NULL THEN NULL
      ELSE (o.sg_event_date::text || 'T' || COALESCE(o.sg_event_time, '00:00:00'))::timestamp
    END AS event_date
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
    s.pulled_at AS last_seen_at,
    -- seatdata has no native event_name; consumer must join v_event_base.
    NULL::text AS event_name,
    NULL::timestamp AS event_date
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
    o.last_seen_at,
    o.event_name,
    o.event_date::timestamp AS event_date
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
    o.last_seen_at,
    o.event_name,
    o.event_date::timestamp AS event_date
FROM public.vivid_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'vivid'::text AND xref.source_status = o.status;
