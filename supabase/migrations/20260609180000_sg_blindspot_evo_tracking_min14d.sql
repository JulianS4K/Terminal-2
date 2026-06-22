-- ============================================================================
-- Migration 20260609180000 — SG-blindspot EVO tracking: exclude < 14 days out
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-06-09
--   (operator-authorized: "exclude anything under 14 days out from that list").
--
-- Lane:     xref+macro (A1 domain) — D0 operator-directed via bot_chat override.
-- Touches:  v_sg_blindspot_evo_tracking (W, view — CREATE OR REPLACE)
-- Pre-reqs: 20260609170000_sg_blindspot_evo_tracking.sql (creates the view + RPC)
--
-- WHY: operator wants near-term events dropped from the blindspot tracking list.
--   Events < 14 days out have little runway to acquire/list into, so they're
--   noise for this surface. Replaces the `> now()` horizon filter with
--   `>= now() + interval '14 days'`. RPC get_sg_blindspot_evo_tracking() is
--   unchanged — it reads this view, so the cutoff applies automatically.
--
-- ROLLBACK: re-apply 20260609170000's view definition (horizon `> now()`).
-- ============================================================================

CREATE OR REPLACE VIEW public.v_sg_blindspot_evo_tracking
WITH (security_invoker = true) AS
WITH latest_sg AS (
  SELECT DISTINCT ON (sg_event_id)
    sg_event_id, tevo_event_id, captured_at AS sg_asof,
    sold_quantity, sold_gross, sold_price_median,
    COALESCE(listings_owned_count, 0) AS sg_owned_listings
  FROM public.seatgeek_event_metrics
  ORDER BY sg_event_id, captured_at DESC
)
SELECT
  row_number() OVER (ORDER BY g.sold_gross DESC NULLS LAST) AS rank,
  s.sg_event_id,
  COALESCE(s.tevo_event_id, g.tevo_event_id) AS tevo_event_id,
  s.sg_event_name AS event_name,
  s.sg_venue_name AS venue_name,
  s.sg_datetime_utc AS event_datetime_utc,
  round(EXTRACT(EPOCH FROM (s.sg_datetime_utc - now())) / 86400.0, 1) AS days_to_event,
  g.sold_quantity AS sg_sold_qty,
  round(g.sold_gross, 2) AS sg_sold_gross,
  round(g.sold_price_median, 2) AS sg_sold_median,
  g.sg_asof,
  em.tickets_count AS evo_tickets,
  em.groups_count AS evo_groups,
  em.getin_price AS evo_getin,
  em.retail_median AS evo_median,
  em.retail_p90 AS evo_p90,
  em.owned_groups_count AS evo_owned_groups,
  em.owned_share AS evo_owned_share,
  em.captured_at AS evo_asof
FROM public.sg_event_priority_state s
JOIN latest_sg g ON g.sg_event_id = s.sg_event_id
LEFT JOIN public.latest_event_metrics em ON em.event_id = COALESCE(s.tevo_event_id, g.tevo_event_id)
WHERE s.tier = 'TRACK_BLINDSPOT'
  AND s.sg_datetime_utc >= now() + interval '14 days'   -- exclude < 14 days out
  AND s.owned_count_last_7d = 0
  AND g.sg_owned_listings = 0
  AND g.sold_quantity > 0;

REVOKE ALL ON public.v_sg_blindspot_evo_tracking FROM anon, authenticated;
