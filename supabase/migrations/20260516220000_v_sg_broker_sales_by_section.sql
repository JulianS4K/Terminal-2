-- Migration 20260516220000 · lane:A1 (D2-authored) · writes:v_sg_broker_sales_by_section (new view) · reads:seatgeek_sales_snapshots,sg_events_canonical · pre:- · auth:operator-permitted 2026-05-16
-- Maps the SG broker sales firehose (seatgeek_sales_snapshots) into the
-- same column shape as the existing seller-side v_sg_sales_by_section view,
-- so a future frontend can render either source through one renderer + UNION
-- when seller seller-side activity resumes.
--
-- Why a parallel view (not a refactor of v_sg_sales_by_section):
--   - v_sg_sales_by_section sources seatgeek_orders (seller-side, 400 dormant rows).
--   - This new view sources seatgeek_sales_snapshots (broker firehose, 900K+ rows,
--     ~67k sales/hour observed market activity).
--   - Same FE shape; different population strategies (UPSERT vs observation).
--
-- DISTINCT ON (sg_sale_id) is MANDATORY per PROJECT_BIBLE.md §3 — broker
-- firehose has an 11x duplication factor (sales re-observed across polls).
-- ORDER BY sg_sale_id, pulled_at DESC picks the latest observation per sale.
--
-- Canonical column name mapping (broker → seller-side equivalent):
--   sg_sale_id        → sale_id (broker uses sg_sale_id; seller uses sg_order_id)
--   broadcast_price   → sale_price
--   quantity          → sale_quantity
--   sale_at_utc       → created_at_sg (when the sale actually transacted)
--   pulled_at         → last_status_at (when we observed it)
--   ('sold' constant) → status (broker observations are always terminal)
-- Plus broker-only fields exposed for FE detail panels:
--   aq_short_event_id, venue_short_id, is_instant, in_hand_date, seller_notes

CREATE OR REPLACE VIEW public.v_sg_broker_sales_by_section AS
SELECT DISTINCT ON (s.sg_sale_id)
  -- Event header (joined from canonical SG event table)
  s.tevo_event_id,
  s.sg_event_id,
  sgc.sg_event_name,
  sgc.sg_event_date,
  sgc.sg_venue_name                                                   AS sg_venue,
  -- Section-level seat info (broker firehose grain)
  s.section,
  s."row",
  s.quantity                                                          AS sale_quantity,
  s.broadcast_price                                                   AS sale_price,
  (s.broadcast_price * COALESCE(s.quantity, 1)::numeric)              AS sale_total_estimate,
  -- Lifecycle: broker sales are observation-time-terminal
  'sold'::text                                                        AS status,
  s.sale_at_utc                                                       AS created_at_sg,
  s.pulled_at                                                         AS last_status_at,
  -- Delivery facts (shape match with v_sg_sales_by_section)
  s.delivery_method,
  s.stock_type,
  -- Broker-only extras (additive — FE can choose to render or ignore)
  s.sg_sale_id,
  s.aq_short_event_id,
  s.venue_short_id,
  s.is_instant,
  s.in_hand_date,
  s.seller_notes
FROM public.seatgeek_sales_snapshots s
LEFT JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = s.sg_event_id
WHERE s.section IS NOT NULL  -- parity with v_sg_sales_by_section's row filter
ORDER BY s.sg_sale_id, s.pulled_at DESC;

REVOKE ALL ON public.v_sg_broker_sales_by_section FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_sg_broker_sales_by_section TO service_role;

COMMENT ON VIEW public.v_sg_broker_sales_by_section IS
  'Section-grain SG broker firehose sales mapped to the v_sg_sales_by_section shape. DISTINCT ON (sg_sale_id) deduplicates the 11x observation factor. Use for FE views that want to UNION seller-side + broker-side SG sales through one renderer.';
