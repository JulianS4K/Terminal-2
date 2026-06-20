-- Migration 20260620153000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — view over AXS primary + cross-source secondary metrics)
-- Touches W: CREATE VIEW public.v_event_primary_vs_secondary
-- Touches R: public.v_axs_listings, public.v_event_price_arbitrage
-- Pre-reqs: v_axs_listings (AXS listing-standard view), v_event_price_arbitrage (mig 20260516120000)
-- Already applied to prod · via MCP 2026-06-20
--
-- ============================================================
-- PRIMARY-vs-SECONDARY SPREAD  ("flip margin vs AXS face")
--
-- We ingest AXS *primary box-office* seat-level pricing (v_axs_listings, src='primary',
-- already normalized to dollars) AND secondary-market getins (TEvo + SeatGeek, via
-- v_event_price_arbitrage). The existing arbitrage rule only compares TEvo<->SG, both
-- secondary. This view surfaces the one spread brokers can't normally see cleanly:
--   secondary get-in  minus  AXS primary face get-in.
--   > 0  => instant flip margin the moment tickets release
--   < 0  => secondary trading BELOW face (dump risk / sell signal)
--
-- v_axs_listings carries every snapshot per event (avg ~4.7, max 82) so we pin to the
-- LATEST snapshot per event (max(snapshot_id)). retail_price is already dollars; we drop
-- 0-price FLASHSEATS placeholder rows. src='primary' excludes the 9000000... resale offers.
--
-- SECURITY INVOKER (default) — respects caller RLS. Granted to authenticated for D0.
-- ============================================================

CREATE OR REPLACE VIEW public.v_event_primary_vs_secondary
WITH (security_invoker = true) AS
WITH latest_axs AS (
  SELECT event_id, max(snapshot_id) AS snap
  FROM public.v_axs_listings
  GROUP BY event_id
),
axs_face AS (
  SELECT
    l.event_id AS tevo_event_id,
    min(l.retail_price) FILTER (WHERE l.retail_price > 0)                                   AS axs_primary_getin,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY l.retail_price)
       FILTER (WHERE l.retail_price > 0)                                                    AS axs_primary_median,
    sum(l.quantity)                                                                         AS axs_primary_qty,
    count(*) FILTER (WHERE l.retail_price > 0)                                              AS axs_primary_listings,
    max(l.captured_at)                                                                      AS axs_captured_at
  FROM public.v_axs_listings l
  JOIN latest_axs la ON la.event_id = l.event_id AND la.snap = l.snapshot_id
  WHERE l.src = 'primary'
  GROUP BY l.event_id
)
SELECT
  a.tevo_event_id,
  arb.event_name,
  arb.venue_name,
  arb.occurs_at_local,
  a.axs_primary_getin,
  a.axs_primary_median,
  a.axs_primary_qty,
  a.axs_primary_listings,
  a.axs_captured_at,
  arb.tevo_retail_min  AS tevo_secondary_getin,
  arb.sg_all_min       AS sg_secondary_getin,
  -- lower non-null secondary get-in (LEAST ignores NULLs in Postgres)
  least(arb.tevo_retail_min, arb.sg_all_min)                                                AS best_secondary_getin,
  round(least(arb.tevo_retail_min, arb.sg_all_min) - a.axs_primary_getin, 2)                AS flip_margin,
  round((least(arb.tevo_retail_min, arb.sg_all_min) - a.axs_primary_getin)
        / NULLIF(a.axs_primary_getin, 0) * 100, 1)                                          AS flip_margin_pct,
  CASE
    WHEN least(arb.tevo_retail_min, arb.sg_all_min) IS NULL THEN 'no_secondary'
    WHEN least(arb.tevo_retail_min, arb.sg_all_min) >= a.axs_primary_getin THEN 'secondary_premium'
    ELSE 'below_face'
  END                                                                                       AS signal,
  arb.sg_metrics_at,
  arb.tevo_metrics_at
FROM axs_face a
JOIN public.v_event_price_arbitrage arb ON arb.tevo_event_id = a.tevo_event_id
WHERE a.axs_primary_getin IS NOT NULL;

COMMENT ON VIEW public.v_event_primary_vs_secondary IS
  'Primary (AXS face, latest snapshot, src=primary) vs secondary (TEvo/SG getin) spread. '
  'flip_margin = best_secondary_getin - axs_primary_getin (>0 flip margin, <0 below-face dump risk). '
  'A1 · mig 20260620153000.';

GRANT SELECT ON public.v_event_primary_vs_secondary TO authenticated, service_role;
