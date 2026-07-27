-- Migration 20260518060000 · lane:A1 (DDL only; writer is cross-lane Python) · writes:event_metrics · pre:20260518050000 · auth:operator-approved 2026-05-18
--
-- A1 PR-5 — add owned_p25/p75/p90 to event_metrics. DDL only (A1 lane).
-- Writer (Python app.py event-processor) lives outside A1 lane; columns sit at
-- NULL until writer-owner ships parallel change. bot_chat handoff posted with
-- the patch template.
--
-- Pattern reference (already used for owned_median_retail):
--   percentile_cont(0.25) WITHIN GROUP (ORDER BY retail_price) FILTER (WHERE is_owned)
-- See compute_event_section_metrics + compute_event_zone_metrics for canonical
-- templates at the section/zone tier.

ALTER TABLE public.event_metrics
  ADD COLUMN IF NOT EXISTS owned_p25 numeric,
  ADD COLUMN IF NOT EXISTS owned_p75 numeric,
  ADD COLUMN IF NOT EXISTS owned_p90 numeric;

COMMENT ON COLUMN public.event_metrics.owned_p25 IS
  'A1 2026-05-18 added. Pattern: percentile_cont(0.25) WITHIN GROUP (ORDER BY retail_price) FILTER (WHERE is_owned). Populated by event-processor (Python app.py) — pending writer-side change.';
COMMENT ON COLUMN public.event_metrics.owned_p75 IS
  'A1 2026-05-18 added. percentile_cont(0.75) ... FILTER (WHERE is_owned). Pending writer-side change.';
COMMENT ON COLUMN public.event_metrics.owned_p90 IS
  'A1 2026-05-18 added. percentile_cont(0.90) ... FILTER (WHERE is_owned). Pending writer-side change.';
