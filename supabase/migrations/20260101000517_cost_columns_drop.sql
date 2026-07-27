-- Migration 20260518050000 · lane:A1 · writes:seatgeek_event_metrics+drops compute_seatgeek_event_metrics · pre:20260518040004 · auth:operator-approved 2026-05-18
--
-- A1 PR-4b — drop the deprecated cost_* columns + retire the legacy populator.
-- Pre-flight verified zero readers via pg_proc + pg_views scan after PR-4a:
--   migrated v_event_price_arbitrage + v_event_full_v2 + v_event_velocity_windows
--   + get_broker_event_page_v2 + get_broker_event_page_v3 all to listings_all_*

DROP FUNCTION IF EXISTS public.compute_seatgeek_event_metrics(bigint);

ALTER TABLE public.seatgeek_event_metrics
  DROP COLUMN IF EXISTS cost_min,
  DROP COLUMN IF EXISTS cost_p25,
  DROP COLUMN IF EXISTS cost_median,
  DROP COLUMN IF EXISTS cost_mean,
  DROP COLUMN IF EXISTS cost_p75,
  DROP COLUMN IF EXISTS cost_p90,
  DROP COLUMN IF EXISTS cost_max,
  DROP COLUMN IF EXISTS cost_sum;

COMMENT ON TABLE public.seatgeek_event_metrics IS
  'Per-event SG-side aggregates. A1 2026-05-18: dropped legacy cost_* columns (SellerDirect-only populator retired). Active columns: listings_all_* (PR #204), listings_owned_* (PR #204), sold_* (PR #161), orders_* (legacy, no active writer), edelivery_share/instant_share/fill_rate/unique_sections/unique_rows (also inert post-drop).';
