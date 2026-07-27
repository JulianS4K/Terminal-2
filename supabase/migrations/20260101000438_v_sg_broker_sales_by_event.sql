-- Migration 20260516220100 · lane:A1 (D2-authored) · writes:v_sg_broker_sales_by_event (new view) · reads:seatgeek_sales_snapshots,sg_events_canonical · pre:20260516220000 · auth:operator-permitted 2026-05-16
-- Per-event aggregator over the SG broker firehose. Mirrors the existing
-- seller-side v_sg_sales_by_event shape so a future FE event-index panel
-- can render either source with the same code path.
--
-- The section-grain companion v_sg_broker_sales_by_section (mig 20260516220000)
-- is the row-level view. This file is the GROUP BY tevo_event_id, sg_event_id
-- rollup — useful for "is this event heating up?" signals on the dashboard.
--
-- Aggregation runs over the DEDUPLICATED set (the section view already does
-- DISTINCT ON sg_sale_id). Inline the dedup CTE here so this view can be
-- queried standalone without depending on the section view.

CREATE OR REPLACE VIEW public.v_sg_broker_sales_by_event AS
WITH dedup AS (
  SELECT DISTINCT ON (s.sg_sale_id)
    s.tevo_event_id, s.sg_event_id, s.sg_sale_id,
    s.quantity, s.broadcast_price, s.section, s.sale_at_utc
  FROM public.seatgeek_sales_snapshots s
  WHERE s.section IS NOT NULL
  ORDER BY s.sg_sale_id, s.pulled_at DESC
)
SELECT
  d.tevo_event_id,
  d.sg_event_id,
  max(sgc.sg_event_name)                              AS sg_event_name,
  max(sgc.sg_event_date)                              AS sg_event_date,
  max(sgc.sg_venue_name)                              AS sg_venue,
  count(*)::bigint                                    AS sales_count,
  sum(d.quantity)::bigint                             AS tickets_sold,
  sum(d.broadcast_price * COALESCE(d.quantity, 1)::numeric) AS gross_estimate,
  min(d.broadcast_price)                              AS min_sale_price,
  round(
    percentile_cont(0.5)
      WITHIN GROUP (ORDER BY d.broadcast_price::double precision)::numeric,
    2
  )                                                   AS median_sale_price,
  max(d.broadcast_price)                              AS max_sale_price,
  count(DISTINCT d.section)::bigint                   AS distinct_sections,
  string_agg(DISTINCT d.section, ',' ORDER BY d.section) AS sections,
  max(d.sale_at_utc)                                  AS latest_sale_at
FROM dedup d
LEFT JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = d.sg_event_id
GROUP BY d.tevo_event_id, d.sg_event_id;

REVOKE ALL ON public.v_sg_broker_sales_by_event FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_sg_broker_sales_by_event TO service_role;

COMMENT ON VIEW public.v_sg_broker_sales_by_event IS
  'Per-event rollup of SG broker firehose sales. Mirrors v_sg_sales_by_event shape (sales_count, tickets_sold, gross_estimate, min/median/max sale_price, distinct_sections, sections, latest_sale_at). Aggregates over the deduplicated set (DISTINCT ON sg_sale_id, latest by pulled_at). Use for FE event-index "heat" signals.';
