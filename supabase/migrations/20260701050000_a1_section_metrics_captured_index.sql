-- ============================================================================
-- Migration 20260701050000 — index section_metrics(captured_at) for retention sweeps
--
-- Lane:     A1
-- Touches:  section_metrics (new index idx_section_metrics_captured).
-- Pre-reqs: none.
--
-- WHY: section_metrics (~57M rows / 11GB) had NO standalone captured_at index — only composites leading
-- with event_id — so sweep_old_section_metrics' `WHERE captured_at < cutoff` seq-scanned 57M rows and
-- always hit the statement timeout (retention never ran → unbounded growth). This adds the missing index.
--
-- NOTE ON BUILD: the actual prod build is done out-of-band by a self-unscheduling pg_cron one-shot
-- (`idxbuild_section_metrics`, statement_timeout=0, maintenance_work_mem=1GB) because a 57M-row build
-- exceeds the 60s MCP execute cap and CREATE INDEX CONCURRENTLY cannot run inside pg_cron's transaction.
-- This file is the schema-of-record; IF NOT EXISTS makes it a no-op once the one-shot has built it.
--
-- Idempotent (IF NOT EXISTS). Re-apply is a no-op.
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_section_metrics_captured
  ON public.section_metrics (captured_at);
