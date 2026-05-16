-- Migration 20260516100000 · admin · evo_orders event-mapping columns + backfill · pre:20260516090000
--
-- Unmapped data sweep audit 2026-05-16 surfaced: `evo_orders` has ZERO event-mapping
-- columns. Cannot join evo_orders to events/aq_event_map directly; must go through
-- `evo_order_items.event_id` (which IS populated). That's an awkward dual-hop for
-- every D0/D2 join.
--
-- This migration:
-- 1. ADD `tevo_event_id` + `aq_short_event_id` columns to `evo_orders` (nullable)
-- 2. Backfill `tevo_event_id` from `evo_order_items.event_id` (DISTINCT ON evo_order_id,
--    in case multi-event orders exist — though rare)
-- 3. Backfill `aq_short_event_id` via the bridge: events ↔ seatgeek_event_xref ↔ aq_event_map
-- 4. Partial index on `tevo_event_id WHERE NOT NULL` for downstream joins
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + WHERE IS NULL guards on UPDATEs.
--
-- Note: New evo_orders rows ingested AFTER this migration won't auto-populate the new
-- columns. That's a Phase B item (update `evo_orders_process` to write tevo_event_id
-- at ingest time). For now the hourly `match_unmatched_orders_sweep` cron catches them
-- via its `evo_order_items` branch — those orders show up there even when evo_orders
-- doesn't have the bridge yet.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16.

ALTER TABLE public.evo_orders
  ADD COLUMN IF NOT EXISTS tevo_event_id     bigint,
  ADD COLUMN IF NOT EXISTS aq_short_event_id text;

-- Backfill tevo_event_id from evo_order_items.event_id
UPDATE public.evo_orders eo
SET tevo_event_id = src.event_id
FROM (
  SELECT DISTINCT ON (evo_order_id)
    evo_order_id, event_id
  FROM public.evo_order_items
  WHERE event_id IS NOT NULL
  ORDER BY evo_order_id, evo_item_id
) src
WHERE eo.evo_order_id = src.evo_order_id
  AND eo.tevo_event_id IS NULL;

-- Backfill aq_short_event_id via two-step bridge
-- Step a: via direct evo_order_items.aq_short_event_id (when items already matched)
UPDATE public.evo_orders eo
SET aq_short_event_id = src.aq_short_event_id
FROM (
  SELECT DISTINCT ON (evo_order_id)
    evo_order_id, aq_short_event_id
  FROM public.evo_order_items
  WHERE aq_short_event_id IS NOT NULL
  ORDER BY evo_order_id, evo_item_id
) src
WHERE eo.evo_order_id = src.evo_order_id
  AND eo.aq_short_event_id IS NULL;

-- Step b: fall back to seatgeek_event_xref → aq_event_map for rows still NULL
UPDATE public.evo_orders eo
SET aq_short_event_id = aem.aq_short_event_id
FROM public.seatgeek_event_xref sgx
JOIN public.aq_event_map aem ON aem.sg_event_id = sgx.sg_event_id
WHERE eo.tevo_event_id = sgx.tevo_event_id
  AND eo.aq_short_event_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_evo_orders_tevo_event_id
  ON public.evo_orders(tevo_event_id) WHERE tevo_event_id IS NOT NULL;
