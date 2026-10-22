-- Migration 20261021164000 · level:admin · lane:A1 · writes:aq_tevo_search_attempts (constraint) · reads:none · pre:20260605133500 (aq_tevo_search_attempts), 20260605150200
--
-- ============================================================================
-- Migration 20261021164000 — accept 'no_name_overlap' in the TEvo search ledger CHECK
--
-- Lane:     A1 (data plane) · 2026-10-21 audit row KANBAN A1-DB-13
-- Touches:  aq_tevo_search_attempts (CHECK constraint widened — W, DDL only)
-- Pre-reqs: 20260605133500_aq_tevo_search_bridge.sql (table + CHECK exist)
--
-- Already applied to prod · via MCP 2026-10-21 under operator direction (the
--   2026-10-21 "apply all three" approval). Verified post-apply: constraint
--   now lists matched / no_results / low_score / errored / no_name_overlap.
--
-- WHY: supabase/functions/aq-to-tevo-search-bridge/index.ts:238-240 writes
--   `result = 'no_name_overlap'` (best candidate scored but the names share no
--   token), but the CHECK from 20260605133500 only allowed matched /
--   no_results / low_score / errored. The INSERT failed every run (468 × 23514
--   in the 24h postgres log, 2026-10-21), the ledger row never landed, and the
--   same hub rows were re-searched against TEvo on every tick — wasted quota
--   and a permanently "unattempted" queue. The function's intent is clearly a
--   fifth distinct outcome, so widen the constraint rather than collapse it to
--   low_score. Existing rows all satisfy the old (stricter) set, so ADD
--   CONSTRAINT validates instantly. `lock_timeout` so a busy table fails fast
--   instead of queueing behind readers.
--
-- NOT in this file (deliberately): dropping the two `indisvalid=false`
--   `*_ccnew` leftovers on gotickets_listings_snapshots (KANBAN A1-DB-8). A
--   plain DROP INDEX needs an AccessExclusive lock on the 130 GB table and
--   queued behind readers past the MCP's 60 s cap (rolled back cleanly);
--   DROP INDEX CONCURRENTLY cannot run inside a migration transaction and must
--   wait for every open transaction (the hourly rollup holds one for 10 min).
--   Run it from psql / the SQL editor in a quiet window, outside a transaction:
--     SET lock_timeout = '30s';
--     DROP INDEX CONCURRENTLY IF EXISTS public.idx_gt_ls_captured_ccnew;
--     DROP INDEX CONCURRENTLY IF EXISTS public.idx_gt_ls_event_time_ccnew;
-- ============================================================================

SET LOCAL lock_timeout = '5s';

ALTER TABLE public.aq_tevo_search_attempts
  DROP CONSTRAINT IF EXISTS aq_tevo_search_attempts_result_check;
ALTER TABLE public.aq_tevo_search_attempts
  ADD CONSTRAINT aq_tevo_search_attempts_result_check
  CHECK (result = ANY (ARRAY['matched', 'no_results', 'low_score', 'errored', 'no_name_overlap']));

-- Post-apply checks:
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conname='aq_tevo_search_attempts_result_check';                        -- includes no_name_overlap  ✔ 2026-10-21
--   (next day) count of 23514 errors naming aq_tevo_search_attempts in postgres_logs -- expect 0
