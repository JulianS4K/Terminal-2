-- Migration 20260518040000 · lane:A1 · writes:v_event_price_arbitrage · reads:seatgeek_event_metrics · pre:20260518030000 · auth:operator-approved 2026-05-18
--
-- A1 PR-4a (part 1 of 5) — migrate v_event_price_arbitrage from legacy cost_*
-- to listings_owned_* (real broker inv) + listings_all_* (full firehose).
--
-- 3-way arbitrage payload now:
--   tevo_retail (TEvo broker board) vs sg_owned (SG broker-held real inv)
--                                    vs sg_all (full SG marketplace including spec)
--                                    vs sg_sale (realized SG sales — already wired)
--
-- DROP+CREATE because column renames inside view aliases.

DROP VIEW IF EXISTS public.v_event_price_arbitrage;

CREATE VIEW public.v_event_price_arbitrage AS
SELECT
  e.id AS tevo_event_id,
  e.name AS event_name,
  e.venue_name,
  e.occurs_at_local,
  sgx.sg_event_id,
  em.retail_median AS tevo_retail_median,
  em.retail_min AS tevo_retail_min,
  em.tickets_count AS tevo_listings_count,
  em.owned_tickets_count,
  sgm.listings_owned_median AS sg_owned_median,
  sgm.listings_owned_min AS sg_owned_min,
  sgm.listings_all_median AS sg_all_median,
  sgm.listings_all_min AS sg_all_min,
  sgm.listings_all_count AS sg_listings_count,
  sgm.sold_price_median AS sg_sale_median_realized,
  sgm.sold_price_mean AS sg_sale_mean_realized,
  sgm.sold_quantity AS sg_sales_count,
  (sgm.sold_price_median - em.retail_median) AS sale_minus_retail_median,
  (sgm.listings_owned_median - em.retail_median) AS sg_owned_minus_retail_median,
  (sgm.listings_all_median - em.retail_median) AS sg_all_minus_retail_median,
  em.captured_at AS tevo_metrics_at,
  sgm.captured_at AS sg_metrics_at
FROM public.events e
LEFT JOIN public.latest_event_metrics em ON em.event_id = e.id
LEFT JOIN public.seatgeek_event_xref sgx ON sgx.tevo_event_id = e.id
LEFT JOIN LATERAL (
  SELECT id, tevo_event_id, sg_event_id, captured_at,
         listings_all_count, listings_all_tickets,
         listings_all_min, listings_all_p25, listings_all_median, listings_all_mean,
         listings_all_p75, listings_all_p90, listings_all_max,
         listings_owned_count, listings_owned_tickets,
         listings_owned_min, listings_owned_p25, listings_owned_median, listings_owned_mean,
         listings_owned_p75, listings_owned_p90, listings_owned_max,
         sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_mean, sold_price_max
  FROM public.seatgeek_event_metrics
  WHERE tevo_event_id = e.id
  ORDER BY captured_at DESC
  LIMIT 1
) sgm ON true
WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
  AND e.occurs_at_local::timestamptz > now()
  AND e.occurs_at_local::timestamptz < now() + interval '180 days';

GRANT SELECT ON public.v_event_price_arbitrage TO anon, authenticated, service_role;

COMMENT ON VIEW public.v_event_price_arbitrage IS
  'A1 2026-05-18 — 3-way price comparison: TEvo retail vs SG owned (broker-held real inv) vs SG all-listings (full firehose incl spec) + SG realized sales. Was reading cost_* legacy cols pre-PR #204; migrated to listings_owned_* and listings_all_* (PR-4a).';
