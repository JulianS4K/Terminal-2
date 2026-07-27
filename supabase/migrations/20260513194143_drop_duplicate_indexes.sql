-- Migration 20260513200200 · level:admin · lane:A1 · writes:pg_index(drop ×2) · reads:pg_index · pre:20260513200100
-- Pre-resume audit response 2026-05-13 — drop duplicate indexes flagged by Supabase
-- DUPLICATE_INDEX advisor.
--
-- Each table has two indexes that cover the exact same column set; one is redundant.
-- Picking the one with the less-descriptive name to drop in each case.
--
-- Reference: audit finding M3. bot_chat row 94 (B1 ping).
--
-- Reversal:
--   CREATE INDEX evo_order_items_event_id_idx        ON public.evo_order_items (event_id);
--   CREATE INDEX section_metrics_event_captured_idx  ON public.section_metrics (event_id, captured_at);

BEGIN;

-- evo_order_items: keep idx_evo_oi_event (shorter, matches naming pattern with siblings).
DROP INDEX IF EXISTS public.evo_order_items_event_id_idx;

-- section_metrics: keep idx_section_metrics_time (matches naming convention used by sibling indexes).
DROP INDEX IF EXISTS public.section_metrics_event_captured_idx;

COMMIT;

-- Verification:
--   SELECT schemaname, tablename, indexname
--   FROM pg_indexes
--   WHERE schemaname='public'
--     AND (tablename = 'evo_order_items' OR tablename = 'section_metrics')
--   ORDER BY tablename, indexname;
-- Expected: only idx_evo_oi_event on evo_order_items (plus PK), only idx_section_metrics_time on section_metrics (plus PK).
