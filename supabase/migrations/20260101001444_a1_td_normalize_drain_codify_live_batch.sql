-- ============================================================================
-- Migration 20260709214500 — Codify the live td_normalize_drain batch size (drift fix)
--
-- Lane:     A1
-- Touches:  cron job 'td_normalize_drain' (reschedule — batch arg only; schedule unchanged).
-- Pre-reqs: 20260629220030 (crank migration — last committed setter, batch 100), td_normalize_drain(int).
--
-- WHY (drift reconciliation 2026-07-09): a prod↔repo audit of the TD cron surface found the whole
-- pipeline (td_pull_drain(20), td_tier_enqueue_* */5, axs-probe-drain peak-only, sg_burn→7/20,
-- td_match_drain(25)) matches the latest committed migrations EXCEPT td_normalize_drain: the repo's
-- last committed setter (20260629220030) schedules batch **100**, but prod has been running **50**
-- (the earlier 20260606192416 value) — i.e. the crank's normalize bump never stuck in prod, or was
-- hand-reset afterward. This codifies the live, working value (50) so the repo reproduces prod.
--
-- Batch size is a pure response-processing knob (no upstream API call, no credit cost): normalize_drain
-- turns already-fired /fetch responses into rows. At the current fire rate (td_pull_drain(20) once/min =
-- ~40 responses per 2-min normalize window) a batch of 50 never saturates, so 50 and 100 are
-- operationally equivalent here; prod (50) is treated as the source of truth to avoid perturbing a
-- healthy pipeline. Raise this alongside td_pull_drain if per-minute fire volume ever exceeds ~50/window.
--
-- Idempotent (cron.schedule upsert by jobname) -> apply-before-PR under operator direction; re-apply is a
-- no-op against the live definition.
-- ============================================================================

SELECT cron.schedule(
  'td_normalize_drain',
  '*/2 * * * *',
  $c$DO $b$ BEGIN PERFORM public.td_normalize_drain(50); END $b$;$c$
);
