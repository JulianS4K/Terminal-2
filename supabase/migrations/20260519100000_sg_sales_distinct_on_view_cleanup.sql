-- Migration 20260519100000 · lane:A1 · writes:seatgeek_event_latest+unified_orders+v_aq_match_quality+v_orphan_seatgeek_data+order_status_coverage+unified_orders_by_event · reads:seatgeek_sales_snapshots · pre:20260518060000 · auth:operator-approved 2026-05-19
--
-- A1 — SG sales DISTINCT ON cleanup. 4 views were aggregating
-- seatgeek_sales_snapshots without DISTINCT ON sg_sale_id, silently
-- overcounting due to append-every-pull design.
--
-- Pre-fix counts on prod (2026-05-19 audit):
--   seatgeek_event_latest.sales_count for event 3091415: 8,431 → true 368 (23×)
--   unified_orders sg_sales rows:                       1,822,446 → 121,202 (15×)
--   v_aq_match_quality sg_sales total:                  1,822,446 → 121,202 (15×)
--   v_orphan_seatgeek_data sales row_count sum:        ~700k     → 45,097 (~15×)
--
-- Convention enforced: DISTINCT ON (sg_sale_id) ORDER BY sg_sale_id, pulled_at DESC.
-- Mirrors PR #161 v_event_sales_metrics_filtered + v_event_sales_velocity pattern.
--
-- CASCADE on unified_orders dropped 2 dependents (unified_orders_by_event +
-- order_status_coverage); recreated below with original definitions. Both
-- inherit corrected counts from the rebuilt unified_orders source.

-- ============================================================
-- 1. seatgeek_event_latest (no dependents)
-- ============================================================
DROP VIEW IF EXISTS public.seatgeek_event_latest;

CREATE VIEW public.seatgeek_event_latest AS
SELECT
  tevo_event_id, sg_event_id, sg_event_name, sg_event_location,
  sg_start_data, last_listings_at, last_sales_at,
  (SELECT count(DISTINCT ls.sglid)
   FROM public.seatgeek_listings_snapshots ls
   WHERE ls.tevo_event_id = x.tevo_event_id
     AND ls.captured_at = (SELECT max(captured_at) FROM public.seatgeek_listings_snapshots WHERE tevo_event_id = x.tevo_event_id)
  ) AS active_listings,
  (SELECT sum(ls.quantity)
   FROM public.seatgeek_listings_snapshots ls
   WHERE ls.tevo_event_id = x.tevo_event_id
     AND ls.captured_at = (SELECT max(captured_at) FROM public.seatgeek_listings_snapshots WHERE tevo_event_id = x.tevo_event_id)
  ) AS active_tickets,
  (SELECT count(*)
   FROM public.seatgeek_listings_snapshots ls
   WHERE ls.tevo_event_id = x.tevo_event_id AND ls.is_broker_owned = true
     AND ls.captured_at = (SELECT max(captured_at) FROM public.seatgeek_listings_snapshots WHERE tevo_event_id = x.tevo_event_id)
  ) AS broker_owned_listings,
  -- A1 2026-05-19: dedup on sg_sale_id to avoid 11–23× overcount
  (SELECT count(*) FROM (
     SELECT DISTINCT ON (sg_sale_id) sg_sale_id
     FROM public.seatgeek_sales_snapshots ss
     WHERE ss.tevo_event_id = x.tevo_event_id
     ORDER BY sg_sale_id, pulled_at DESC
   ) deduped
  ) AS sales_count,
  (SELECT max(ss.sale_at_utc) FROM public.seatgeek_sales_snapshots ss WHERE ss.tevo_event_id = x.tevo_event_id) AS last_sale_at
FROM public.seatgeek_event_xref x;

GRANT SELECT ON public.seatgeek_event_latest TO anon, authenticated, service_role;
COMMENT ON VIEW public.seatgeek_event_latest IS
  'A1 2026-05-19: sales_count dedup via DISTINCT ON (sg_sale_id). Was reporting 11–23×.';

-- ============================================================
-- 2. unified_orders + 2 dependents (CASCADE rebuild)
-- ============================================================
DROP VIEW IF EXISTS public.unified_orders CASCADE;

CREATE VIEW public.unified_orders AS
SELECT 'evo'::text AS source,
    (o.evo_order_id)::text AS source_order_id,
    (SELECT min(i.event_id) FROM public.evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS tevo_event_id,
    NULL::text AS sg_event_id,
    o.state AS source_status,
    xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    o.type AS source_type,
    (SELECT sum((i.price * (i.quantity)::numeric)) FROM public.evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS gross_value,
    (SELECT sum(i.quantity) FROM public.evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS quantity,
    o.buyer_name, o.seller_name, o.client_name,
    o.evo_created_at AS created_at, o.evo_updated_at AS updated_at, o.last_seen_at,
    (SELECT i.event_name FROM public.evo_order_items i WHERE i.evo_order_id = o.evo_order_id ORDER BY i.evo_item_id LIMIT 1) AS event_name,
    (SELECT i.occurs_at FROM public.evo_order_items i WHERE i.evo_order_id = o.evo_order_id ORDER BY i.evo_item_id LIMIT 1) AS event_date,
    (SELECT i.aq_short_event_id FROM public.evo_order_items i WHERE i.evo_order_id = o.evo_order_id AND i.aq_short_event_id IS NOT NULL LIMIT 1) AS aq_short_event_id
FROM public.evo_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'evo' AND xref.source_status = o.state
UNION ALL
SELECT 'seatgeek'::text AS source,
    o.sg_order_id AS source_order_id, o.tevo_event_id, (o.sg_event_id)::text AS sg_event_id,
    o.status AS source_status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    NULL::text AS source_type, o.payment_total AS gross_value, (o.sale_quantity)::bigint AS quantity,
    NULL::text AS buyer_name, NULL::text AS seller_name, NULL::text AS client_name,
    o.created_at_sg AS created_at, o.last_status_at AS updated_at, o.last_status_at AS last_seen_at,
    o.sg_event_name AS event_name,
    CASE WHEN o.sg_event_date IS NULL THEN NULL::timestamp without time zone
         ELSE (((o.sg_event_date)::text || 'T' || COALESCE(o.sg_event_time, '00:00:00')))::timestamp without time zone END AS event_date,
    o.aq_short_event_id
FROM public.seatgeek_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'seatgeek' AND xref.source_status = o.status
UNION ALL
-- A1 2026-05-19: dedup on sg_sale_id. Was emitting 15× duplicate rows.
SELECT 'seatgeek_sales'::text AS source,
    s.sg_sale_id AS source_order_id, NULL::bigint AS tevo_event_id, (s.sg_event_id)::text AS sg_event_id,
    'sold'::text AS source_status, 'fulfilled'::text AS canonical_status,
    true AS is_terminal, true AS is_sale_succeeded, NULL::text AS source_type,
    (s.broadcast_price * (COALESCE(s.quantity, 1))::numeric) AS gross_value,
    (s.quantity)::bigint AS quantity,
    NULL::text AS buyer_name, NULL::text AS seller_name, NULL::text AS client_name,
    s.sale_at_utc AS created_at, s.pulled_at AS updated_at, s.pulled_at AS last_seen_at,
    (SELECT sgc.sg_event_name FROM public.sg_events_canonical sgc WHERE sgc.sg_event_id = s.sg_event_id) AS event_name,
    (SELECT (sgc.sg_datetime_utc)::timestamp without time zone FROM public.sg_events_canonical sgc WHERE sgc.sg_event_id = s.sg_event_id) AS event_date,
    s.aq_short_event_id
FROM (
  SELECT DISTINCT ON (sg_sale_id)
    sg_sale_id, sg_event_id, broadcast_price, quantity, sale_at_utc, pulled_at, aq_short_event_id
  FROM public.seatgeek_sales_snapshots
  WHERE sg_sale_id IS NOT NULL
  ORDER BY sg_sale_id, pulled_at DESC
) s
UNION ALL
SELECT 'seatdata'::text AS source,
    s.content_hash AS source_order_id, s.tevo_event_id, NULL::text AS sg_event_id,
    'sold'::text AS source_status, 'fulfilled'::text AS canonical_status,
    true AS is_terminal, true AS is_sale_succeeded, NULL::text AS source_type,
    (s.price * (COALESCE(NULLIF(s.quantity, 0), 1))::numeric) AS gross_value,
    (s.quantity)::bigint AS quantity,
    NULL::text AS buyer_name, NULL::text AS seller_name, NULL::text AS client_name,
    s.sale_timestamp AS created_at, s.sale_timestamp AS updated_at, s.pulled_at AS last_seen_at,
    NULL::text AS event_name, NULL::timestamp without time zone AS event_date, NULL::text AS aq_short_event_id
FROM public.seatdata_sales_snapshots s
UNION ALL
SELECT 'tickpick'::text AS source,
    o.tp_order_id AS source_order_id, o.tevo_event_id, NULL::text AS sg_event_id,
    o.status AS source_status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    NULL::text AS source_type, o.total AS gross_value, (o.quantity)::bigint AS quantity,
    NULL::text AS buyer_name, NULL::text AS seller_name, NULL::text AS client_name,
    COALESCE(o.ordered_at, o.pulled_at) AS created_at, o.last_seen_at AS updated_at, o.last_seen_at,
    o.event_name, (o.event_date)::timestamp without time zone AS event_date, o.aq_short_event_id
FROM public.tickpick_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'tickpick' AND xref.source_status = o.status
UNION ALL
SELECT 'vivid'::text AS source,
    o.vivid_order_id AS source_order_id, o.tevo_event_id, NULL::text AS sg_event_id,
    o.status AS source_status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    NULL::text AS source_type, o.total AS gross_value, (o.quantity)::bigint AS quantity,
    NULLIF(concat_ws(' ', o.first_name, o.last_name), '') AS buyer_name,
    NULL::text AS seller_name, NULL::text AS client_name,
    COALESCE(o.ordered_at, o.pulled_at) AS created_at, o.last_seen_at AS updated_at, o.last_seen_at,
    o.event_name, (o.event_date)::timestamp without time zone AS event_date, o.aq_short_event_id
FROM public.vivid_orders o
LEFT JOIN public.order_status_xref xref ON xref.source = 'vivid' AND xref.source_status = o.status;

GRANT SELECT ON public.unified_orders TO anon, authenticated, service_role;
COMMENT ON VIEW public.unified_orders IS
  'A1 2026-05-19: seatgeek_sales source dedup via DISTINCT ON (sg_sale_id). Was emitting 15× rows.';

CREATE VIEW public.unified_orders_by_event AS
SELECT tevo_event_id, source,
    count(*) AS rows,
    count(*) FILTER (WHERE NOT is_terminal) AS in_flight,
    count(*) FILTER (WHERE is_sale_succeeded) AS fulfilled,
    count(*) FILTER (WHERE canonical_status = 'rejected') AS rejected,
    count(*) FILTER (WHERE canonical_status = 'cancelled') AS cancelled,
    count(*) FILTER (WHERE canonical_status = 'pending') AS pending,
    count(*) FILTER (WHERE canonical_status = 'accepted') AS accepted,
    count(*) FILTER (WHERE canonical_status = 'substitution') AS substitution,
    sum(gross_value) FILTER (WHERE is_sale_succeeded) AS gross_sold,
    sum(quantity) FILTER (WHERE is_sale_succeeded) AS tickets_sold,
    min(created_at) AS first_order_at,
    max(updated_at) AS last_update_at
FROM public.unified_orders
WHERE tevo_event_id IS NOT NULL
GROUP BY tevo_event_id, source;

GRANT SELECT ON public.unified_orders_by_event TO anon, authenticated, service_role;

CREATE VIEW public.order_status_coverage AS
SELECT source, canonical_status,
    count(*) AS rows,
    (min(created_at))::date AS earliest,
    (max(updated_at))::date AS latest,
    round(avg(quantity), 2) AS avg_qty,
    round(sum(gross_value), 2) AS sum_gross
FROM public.unified_orders
GROUP BY source, canonical_status
ORDER BY source, canonical_status;

GRANT SELECT ON public.order_status_coverage TO anon, authenticated, service_role;

-- ============================================================
-- 3. v_aq_match_quality
-- ============================================================
DROP VIEW IF EXISTS public.v_aq_match_quality;
CREATE VIEW public.v_aq_match_quality AS
SELECT 'vivid_orders'::text AS source_table,
       count(*) AS total, count(aq_short_event_id) AS with_aq,
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%') AS synthetic,
       round((100.0 * count(aq_short_event_id) / NULLIF(count(*), 0))::numeric, 1) AS pct_aq
FROM public.vivid_orders
UNION ALL
SELECT 'tickpick_orders'::text, count(*), count(aq_short_event_id),
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%'),
       round((100.0 * count(aq_short_event_id) / NULLIF(count(*), 0))::numeric, 1)
FROM public.tickpick_orders
UNION ALL
SELECT 'seatgeek_orders'::text, count(*), count(aq_short_event_id),
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%'),
       round((100.0 * count(aq_short_event_id) / NULLIF(count(*), 0))::numeric, 1)
FROM public.seatgeek_orders
UNION ALL
-- A1 2026-05-19: dedup on sg_sale_id. Total/with_aq/synthetic were 15×.
SELECT 'seatgeek_sales_snapshots'::text, count(*), count(aq_short_event_id),
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%'),
       round((100.0 * count(aq_short_event_id) / NULLIF(count(*), 0))::numeric, 1)
FROM (
  SELECT DISTINCT ON (sg_sale_id) sg_sale_id, aq_short_event_id
  FROM public.seatgeek_sales_snapshots
  ORDER BY sg_sale_id, pulled_at DESC
) deduped_sales
UNION ALL
SELECT 'evo_order_items'::text, count(*), count(aq_short_event_id),
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%'),
       round((100.0 * count(aq_short_event_id) / NULLIF(count(*), 0))::numeric, 1)
FROM public.evo_order_items;

GRANT SELECT ON public.v_aq_match_quality TO anon, authenticated, service_role;
COMMENT ON VIEW public.v_aq_match_quality IS
  'A1 2026-05-19: seatgeek_sales_snapshots row dedups on sg_sale_id. Was 15×.';

-- ============================================================
-- 4. v_orphan_seatgeek_data
-- ============================================================
DROP VIEW IF EXISTS public.v_orphan_seatgeek_data;
CREATE VIEW public.v_orphan_seatgeek_data AS
WITH ignored AS (
  SELECT sg_event_id FROM public.sg_events_canonical WHERE match_status = 'ignored_historic'
)
SELECT 'listings'::text AS kind, seatgeek_listings_snapshots.sg_event_id,
       count(*) AS row_count, max(seatgeek_listings_snapshots.captured_at) AS last_seen
FROM public.seatgeek_listings_snapshots
WHERE seatgeek_listings_snapshots.tevo_event_id IS NULL
  AND NOT (seatgeek_listings_snapshots.sg_event_id IN (SELECT sg_event_id FROM ignored))
GROUP BY seatgeek_listings_snapshots.sg_event_id
UNION ALL
-- A1 2026-05-19: dedup on sg_sale_id. row_count was 11–23×.
SELECT 'sales'::text AS kind, sg_event_id,
       count(*) AS row_count, max(pulled_at) AS last_seen
FROM (
  SELECT DISTINCT ON (sg_sale_id) sg_sale_id, sg_event_id, pulled_at
  FROM public.seatgeek_sales_snapshots
  WHERE tevo_event_id IS NULL AND sg_sale_id IS NOT NULL
  ORDER BY sg_sale_id, pulled_at DESC
) deduped_sales
WHERE NOT (sg_event_id IN (SELECT sg_event_id FROM ignored))
GROUP BY sg_event_id
UNION ALL
SELECT 'orders'::text AS kind, seatgeek_orders.sg_event_id,
       count(*) AS row_count, max(seatgeek_orders.pulled_at) AS last_seen
FROM public.seatgeek_orders
WHERE seatgeek_orders.tevo_event_id IS NULL
  AND seatgeek_orders.sg_event_id IS NOT NULL
  AND NOT (seatgeek_orders.sg_event_id IN (SELECT sg_event_id FROM ignored))
GROUP BY seatgeek_orders.sg_event_id
UNION ALL
SELECT 'seller_listings'::text AS kind, seatgeek_seller_listings.sg_event_id,
       count(*) AS row_count, max(seatgeek_seller_listings.pulled_at) AS last_seen
FROM public.seatgeek_seller_listings
WHERE seatgeek_seller_listings.tevo_event_id IS NULL
  AND NOT (seatgeek_seller_listings.sg_event_id IN (SELECT sg_event_id FROM ignored))
GROUP BY seatgeek_seller_listings.sg_event_id;

GRANT SELECT ON public.v_orphan_seatgeek_data TO anon, authenticated, service_role;
COMMENT ON VIEW public.v_orphan_seatgeek_data IS
  'A1 2026-05-19: sales kind dedup via DISTINCT ON (sg_sale_id). row_count was 11–23×.';
