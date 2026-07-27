-- ============================================================================
-- Migration 20260621001000 — schedule SeatGeek discovery crons (discover + drain)
--
-- Lane:     A1 (data plane — owns td_* SeatGeek discovery + pg_cron schedule)
-- Touches:  cron.job (W, via cron.schedule/unschedule)
-- Pre-reqs: 20260621000500_fix_td_sg_discover_drain_shape.sql — MUST apply first
--           (this schedules the drain; scheduling the pre-fix drain would error
--            every run). Same PR, lower timestamp, so file-order guarantees it.
--
-- WHY: td_sg_discover (crawl td_sg_performers allowlist on SeatGeek) and
--   td_sg_discover_drain (land results into sg_events_canonical) had NO cron —
--   the path had never run (every td_sg_performers.last_discovered_at was NULL).
--   The allowlist (now incl. UFC, performer 25507) only gets crawled if these
--   fire. Mirrors the existing GT/TM discovery cadence (daily, ~15 min apart):
--     td_gt_discover 15 9 * * *  /  td_gt_discover_drain 20 9 * * *
--
-- CADENCE + BUDGET: discover runs daily with p_limit=5; td_sg_discover's own
--   guard (last_discovered_at < 7 days AND pending IS NULL) means each performer
--   is crawled at most weekly, so steady-state is a handful of TD /events credits
--   per day. td_budget_ok() still hard-gates spend. Drain is credit-light
--   (1 credit/processed response) and only acts on landed responses.
--
-- IDEMPOTENT: unschedule any prior same-named jobs, then (re)schedule.
-- ============================================================================

-- Drop prior definitions if present (idempotent re-run / re-apply).
DO $mig$
DECLARE j bigint;
BEGIN
  FOR j IN SELECT jobid FROM cron.job
           WHERE jobname IN ('td_sg_discover_daily','td_sg_discover_drain_daily')
  LOOP PERFORM cron.unschedule(j); END LOOP;
END $mig$;

-- Crawl the SeatGeek discovery allowlist (gated internally to weekly/performer).
SELECT cron.schedule(
  'td_sg_discover_daily', '40 9 * * *',
  $cmd$ DO $b$ BEGIN PERFORM public.td_sg_discover(5); END $b$; $cmd$
);

-- Land discovery responses into sg_events_canonical (then auto_match runs inside).
SELECT cron.schedule(
  'td_sg_discover_drain_daily', '50 9 * * *',
  $cmd$ DO $b$ BEGIN PERFORM public.td_sg_discover_drain(); END $b$; $cmd$
);
