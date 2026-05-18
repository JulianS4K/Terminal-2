-- A1 PR-4a (part 2 of 5) — migrate v_event_full_v2 (cost_* → listings_all_*).
-- DROP+CREATE because column renames inside view aliases.

DROP VIEW IF EXISTS public.v_event_full_v2;

CREATE VIEW public.v_event_full_v2 AS
SELECT
  ef.tevo_event_id, ef.tevo_name, ef.event_date, ef.tevo_venue_name,
  ef.canonical_label, ef.lifecycle_status, ef.sources_count,
  ef.espn_event_id, ef.sd_event_id, ef.sg_event_id, ef.sg_category,
  ef.home_performer, ef.venue,
  ef.tevo_pricing, ef.sg_pricing, ef.sg_seller_pricing, ef.sd_pricing,
  sgm.captured_at AS sg_metrics_captured_at,
  -- A1 2026-05-18 PR-4a: cost_* swap → listings_all_*
  sgm.listings_all_count AS sg_metrics_listings_all,
  sgm.listings_all_tickets AS sg_metrics_listings_all_tix,
  sgm.listings_all_min AS sg_metrics_listings_all_min,
  sgm.listings_all_median AS sg_metrics_listings_all_median,
  sgm.listings_all_p90 AS sg_metrics_listings_all_p90,
  sgm.listings_owned_count AS sg_metrics_listings_owned,
  sgm.listings_owned_median AS sg_metrics_listings_owned_median,
  sgm.orders_open AS sg_metrics_orders_open,
  sgm.orders_fulfilled AS sg_metrics_orders_fulfilled,
  sgm.sold_quantity AS sg_metrics_sold_qty,
  sgm.sold_gross AS sg_metrics_sold_gross,
  sgm.fill_rate AS sg_metrics_fill_rate,
  es.captured_at AS sentiment_captured_at,
  es.sentiment_index,
  es.tix_per_hour,
  es.getin_per_hour,
  es.owned_share_change,
  es.pairs_change_per_hour
FROM public.v_event_full ef
LEFT JOIN LATERAL (
  SELECT captured_at,
    listings_all_count, listings_all_tickets,
    listings_all_min, listings_all_p25, listings_all_median, listings_all_mean,
    listings_all_p75, listings_all_p90, listings_all_max,
    listings_owned_count, listings_owned_tickets,
    listings_owned_min, listings_owned_median, listings_owned_max,
    orders_open, orders_pending, orders_confirmed, orders_fulfilled, orders_delivered, orders_cancelled,
    sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_mean, sold_price_max,
    edelivery_share, instant_share, unique_sections, unique_rows, fill_rate
  FROM public.seatgeek_event_metrics
  WHERE tevo_event_id = ef.tevo_event_id
  ORDER BY captured_at DESC LIMIT 1
) sgm ON true
LEFT JOIN LATERAL (
  SELECT captured_at, sentiment_index, tix_per_hour, getin_per_hour, owned_share_change, pairs_change_per_hour
  FROM public.event_sentiment
  WHERE event_id = ef.tevo_event_id
  ORDER BY captured_at DESC LIMIT 1
) es ON true;

GRANT SELECT ON public.v_event_full_v2 TO anon, authenticated, service_role;
