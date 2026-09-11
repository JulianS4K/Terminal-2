-- Already applied to prod · via MCP 2026-09-11 under operator direction.
-- Migration 20260911240000 · level:cron · lane:A1 · writes:cron.job(venue_section_rollup_hourly) · reads:none · pre:20260911230000
--
-- ============================================================================
-- Migration 20260911240000 — give the agg rebuild room inside the 600s fire
--
-- Lane:     A1 (data plane — crons)
-- Touches:  cron.job (venue_section_rollup_hourly → command body only)
-- Pre-reqs: 20260911230000 (the re-enable), 20260705153500 (catchup + aggs)
--
-- ── WHAT THE FIRST FIRE AFTER THE RESTART SHOWED ───────────────────────────
-- 2026-09-11 20:52:12 UTC, the first run in 44 days:
--   status  failed after 616s
--   ERROR   canceling statement due to statement timeout
--   CONTEXT WITH reps AS (SELECT DISTINCT ON (event_id, section_key) *
--                         FROM public.venue_section_price_daily WHERE perfor...
-- That CONTEXT is refresh_venue_section_aggs(), NOT the day rollups. The day
-- loop ran fine and used its full 300s budget; the agg rebuild then had ~300s
-- left, needed more, and took the whole transaction down with it — the cron
-- body is one BEGIN..COMMIT, so the completed day work rolled back too.
--
-- venue_section_price_daily is unchanged in size (frozen at 7.1M rows since
-- 2026-07-29), so the agg rebuild did not get slower — the day loop got
-- greedier. In steady state the catchup found ~1 missing day per fire (see
-- venue_section_rollup_state: 07-29 sealed at 23:52, 07-28 at 12:52) and the
-- aggs inherited most of the 600s. With a 43-day backlog it wants its full
-- p_max_days=3, starving the rebuild that runs after it.
--
-- Left as-is this LIVELOCKS: every hour burns ~600s of IO and commits nothing,
-- and the backlog never moves.
--
-- ── THE CHANGE ─────────────────────────────────────────────────────────────
-- Cron body only: venue_section_rollup_catchup(3, 300) → (2, 200).
--   * p_max_days 3→2  — today (always ord 0) + ONE backlog day per fire.
--     NOT 1: today always wins the LIMIT, so p_max_days=1 would refresh today
--     forever and never touch the backlog.
--   * p_budget_seconds 300→200 — bounds the day loop so the agg rebuild
--     inherits ~400s of the 600s cap instead of ~300s.
-- Nothing else changes: same schedule, same function, same 600s SET LOCAL.
-- Drains ~1 backlog day per hour → 43 days clears in ~2 days, still well
-- inside the 2026-09-28 raw-TTL deadline (mig 20260911230000 header).
--
-- ── WHAT THIS DOES NOT FIX ─────────────────────────────────────────────────
-- The real defect is structural: a FULL two-table agg rebuild runs inside
-- every rollup fire, in the same transaction as the day work, so a slow
-- rebuild discards good day rollups. The durable fix is the one the original
-- author named — scope the rebuild to touched venues, or move it to its own
-- cron with its own budget so day progress commits independently. That is a
-- rewrite of an A1 function and is deliberately NOT done here; filed for an
-- operator call. This migration only stops the bleeding.
--
-- Reversible: restore the body to venue_section_rollup_catchup(3, 300).
-- Idempotent: cron.alter_job on a fixed body. No data written or deleted.
-- ============================================================================

DO $do$
DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'venue_section_rollup_hourly';
  IF v_jobid IS NULL THEN
    RAISE EXCEPTION 'venue_section_rollup_hourly is not scheduled';
  END IF;

  PERFORM cron.alter_job(
    v_jobid,
    command := $cron$BEGIN; SET LOCAL statement_timeout='600s'; DO $b$ BEGIN
    IF NOT public.cron_should_fire('venue_section_rollup_hourly') THEN RETURN; END IF;
    PERFORM public.venue_section_rollup_catchup(2, 200);
  END $b$; COMMIT;$cron$
  );
END $do$;

-- Self-check: the body carries the new budget and the job is still on.
DO $do$
DECLARE v_cmd text; v_active boolean;
BEGIN
  SELECT command, active INTO v_cmd, v_active
    FROM cron.job WHERE jobname = 'venue_section_rollup_hourly';

  IF NOT coalesce(v_active, false) THEN
    RAISE EXCEPTION 'venue_section_rollup_hourly is not active';
  END IF;
  IF v_cmd NOT LIKE '%venue_section_rollup_catchup(2, 200)%' THEN
    RAISE EXCEPTION 'cron body was not updated: %', left(v_cmd, 200);
  END IF;
  IF v_cmd NOT LIKE '%cron_should_fire%' THEN
    RAISE EXCEPTION 'cron body lost its policy gate';
  END IF;
END $do$;
