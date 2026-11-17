-- Migration 20260831223945 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_conform_to_aq_hub" (version 20260831223945) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831260000 — conform S4K orders to the AQ hub pattern
-- Lane:     xref+macro
-- Touches:  s4k_marketplace_orders (W), s4k_map_legacy (W)
-- Pre-reqs: 20260831240000 (s4k_marketplace_orders must exist)
-- Full rationale in supabase/migrations/20260831260000_xref_s4k_conform_to_aq_hub.sql
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.s4k_map_legacy (
  source          text        NOT NULL,
  order_id        text        NOT NULL,
  tevo_event_id   bigint,
  map_method      text,
  map_confidence  numeric,
  mapped_at       timestamptz,
  snapshot_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, order_id)
);

COMMENT ON TABLE public.s4k_map_legacy IS
  'Disposable audit artifact: S4K order->tevo mapping produced by the interim bespoke name/date matcher (dropped 2026-08-31), kept to diff against the canonical AQ-hub re-derivation. Safe to drop once verified.';

INSERT INTO public.s4k_map_legacy (source, order_id, tevo_event_id, map_method, map_confidence, mapped_at)
SELECT source, order_id, tevo_event_id, map_method, map_confidence, mapped_at
  FROM public.s4k_marketplace_orders
 WHERE tevo_event_id IS NOT NULL
ON CONFLICT (source, order_id) DO NOTHING;

ALTER TABLE public.s4k_marketplace_orders
  ADD COLUMN IF NOT EXISTS aq_short_event_id  text,
  ADD COLUMN IF NOT EXISTS venue_short_id     text,
  ADD COLUMN IF NOT EXISTS performer_short_id text;

CREATE INDEX IF NOT EXISTS s4k_orders_aq_short_event_id_idx
  ON public.s4k_marketplace_orders (aq_short_event_id)
  WHERE aq_short_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS s4k_orders_unmatched_group_idx
  ON public.s4k_marketplace_orders (source, event_date, venue_name)
  WHERE aq_short_event_id IS NULL;

UPDATE public.s4k_marketplace_orders
   SET tevo_event_id = NULL, map_method = NULL,
       map_confidence = NULL, mapped_at = NULL
 WHERE tevo_event_id IS NOT NULL;

DROP FUNCTION IF EXISTS public.s4k_orders_map_events(integer);
;
