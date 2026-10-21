-- Migration 20261021164000 · level:admin · lane:A1 · writes:aq_tevo_search_attempts (constraint) · reads:none · pre:20260605133500 (aq_tevo_search_attempts), 20260605150200
--
-- ============================================================================
-- Migration 20261021164000 — drop 2 INVALID leftover indexes; accept 'no_name_overlap' in the TEvo search ledger
--
-- Lane:     A1 (data plane) · 2026-10-21 audit rows KANBAN A1-DB-8, A1-DB-13
-- Touches:  gotickets_listings_snapshots (2 invalid indexes dropped — W, DDL only)
--           aq_tevo_search_attempts (CHECK constraint widened — W, DDL only)
-- Pre-reqs: 20260605133500_aq_tevo_search_bridge.sql (table + CHECK exist)
--
-- WHY (indexes): `idx_gt_ls_captured_ccnew` and `idx_gt_ls_event_time_ccnew` are
--   `indisvalid = false` leftovers of a REINDEX CONCURRENTLY that did not finish
--   (advisor 0009 duplicate_index). An invalid index is never used by the planner
--   but IS maintained on every write (and the table is 130 GB), so they are pure
--   cost. The valid originals (`idx_gt_ls_captured`, `idx_gt_ls_event_time`) stay.
--   Plain DROP INDEX takes a brief AccessExclusive lock on the table; the
--   GoTickets poller is paused (mig 20260927043400), so there is no writer to
--   block. If it has been resumed by apply time, run `DROP INDEX CONCURRENTLY`
--   out of a transaction instead.
--
-- WHY (CHECK): supabase/functions/aq-to-tevo-search-bridge/index.ts:238-240
--   writes `result = 'no_name_overlap'` (best candidate scored but the names
--   share no token), but the CHECK from 20260605133500 only allows matched /
--   no_results / low_score / errored. The INSERT fails every run (468 × 23514
--   in the 24h postgres log, 2026-10-21), the ledger row never lands, and the
--   same hub rows are re-searched against TEvo on every tick — wasted quota and
--   a permanently "unattempted" queue. The function's intent is clearly a fifth
--   distinct outcome, so widen the constraint rather than collapse it to
--   low_score. Existing rows all satisfy the old (stricter) set, so ADD
--   CONSTRAINT validates instantly.
-- ============================================================================

DROP INDEX IF EXISTS public.idx_gt_ls_captured_ccnew;
DROP INDEX IF EXISTS public.idx_gt_ls_event_time_ccnew;

ALTER TABLE public.aq_tevo_search_attempts
  DROP CONSTRAINT IF EXISTS aq_tevo_search_attempts_result_check;
ALTER TABLE public.aq_tevo_search_attempts
  ADD CONSTRAINT aq_tevo_search_attempts_result_check
  CHECK (result = ANY (ARRAY['matched', 'no_results', 'low_score', 'errored', 'no_name_overlap']));

-- Post-apply checks:
--   SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;              -- expect 0 rows
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conname='aq_tevo_search_attempts_result_check';                        -- includes no_name_overlap
--   (next day) count of 23514 errors naming aq_tevo_search_attempts in postgres_logs -- expect 0
