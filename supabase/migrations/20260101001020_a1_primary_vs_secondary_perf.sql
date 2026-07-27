-- Migration 20260620190000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — performance fix for v_event_primary_vs_secondary)
-- Touches W: CREATE OR REPLACE VIEW public.v_event_primary_vs_secondary
-- Touches R: public.v_axs_listings, public.axs_events, public.v_event_price_arbitrage
-- Pre-reqs: v_event_primary_vs_secondary (mig 20260620153000)
-- Already applied to prod · via MCP 2026-06-20 (30s+ -> sub-ms; 64 events incl. Bocelli)
--
-- The original view computed `max(snapshot_id)` over the WHOLE v_axs_listings firehose
-- view (seat+section AXS snapshots) on every call -> 30s+ timeouts, too slow for the
-- compute_alerts_tick rule and for interactive use. axs_events.last_snapshot_id already
-- tracks the latest snapshot per event, so we pin to it instead — sub-millisecond, no
-- firehose max(). Same columns/semantics; verified Bocelli + 64 events + avg flip $54.
-- max(last_snapshot_id) per tevo_event_id guards against duplicate axs_events rows.
-- ============================================================

CREATE OR REPLACE VIEW public.v_event_primary_vs_secondary
WITH (security_invoker = true) AS
WITH latest_axs AS (
  SELECT tevo_event_id, max(last_snapshot_id) AS snap
  FROM public.axs_events
  WHERE tevo_event_id IS NOT NULL AND last_snapshot_id IS NOT NULL
  GROUP BY tevo_event_id
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
  JOIN latest_axs la ON la.tevo_event_id = l.event_id AND la.snap = l.snapshot_id
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
  'Primary (AXS face, latest snapshot via axs_events.last_snapshot_id, src=primary) vs '
  'secondary (TEvo/SG getin) spread. flip_margin = best_secondary_getin - axs_primary_getin. '
  'A1 · mig 20260620153000, perf 20260620190000.';

GRANT SELECT ON public.v_event_primary_vs_secondary TO authenticated, service_role;
