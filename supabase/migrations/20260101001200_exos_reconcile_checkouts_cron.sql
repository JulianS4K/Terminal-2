-- ============================================================================
-- Migration 20260702144637 — Exos (Bridge / D4): schedule checkout reconcile
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  cron.schedule (exos-reconcile-checkouts-15min)
-- Pre-reqs: 20260511000200 (_cron_invoke_edge_fn + vault CRON_SECRET/anon JWT),
--           edge fn exos-reconcile-checkouts deployed
--
-- Schedules the charged-but-no-ticket safety net (audit 2026-07-02). Runs every
-- 15 min at off-cluster minutes (:13/:28/:43/:58 — avoids the saturated
-- :00/:05/:07 marks per MIGRATION_CONVENTIONS). The edge fn retries fulfillment
-- for paid-but-pending sessions (missed webhook) and auto-refunds failed-but-
-- charged sessions. Cron secret + anon JWT are pulled from vault by
-- _cron_invoke_edge_fn; the fn re-checks the cron secret body-side.
-- D4 authors; A1 applies to prod (DB apply + edge fn deploy).
-- ============================================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-reconcile-checkouts-15min') THEN
    PERFORM cron.unschedule('exos-reconcile-checkouts-15min');
  END IF;
END $$;

SELECT cron.schedule(
  'exos-reconcile-checkouts-15min',
  '13,28,43,58 * * * *',
  $cron$
    SELECT public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-reconcile-checkouts',
      '{}'::jsonb
    );
  $cron$
);

-- ROLLBACK: SELECT cron.unschedule('exos-reconcile-checkouts-15min');
