-- ============================================================================
-- Migration 20260708164500 — refresh_movers_agg cron budget 840s → 2700s
--
-- Lane:     A1
-- Touches:  cron.job command only (refresh_movers_agg).
-- Pre-reqs: 20260708042000 (gate-clamp fix — without it any prefix is clobbered
--           to 120s after the gate call), 20260702075500 (prior 840s prefix).
--
-- WHY (operator-approved stopgap, 2026-07-08): the 2026-07-08 manual backfill
--   measured per-window cold costs w7 ~24min · w15+w30 ~26min pair · w180
--   ~27min · w365 ~37min — every window now exceeds the 840s per-statement
--   budget, so the 07:20/19:20 runs kept failing even after the gate-clamp
--   fix. Input growth drivers: TD-SG burn enrollment (~1,948 events) + re-lit
--   SG sales since 07-02. 2700s (45min) per statement covers the worst
--   observed window with ~20% headroom. Accepted trade-off: the job can hold
--   a scheduler slot up to ~2h per fire (use_background_workers=off).
--   Proper fix tracked in KANBAN A1-OPS-29 (same PR): fast-by-construction
--   rewrite of refresh_event_movers_agg per the PROJECT_BIBLE §3 doctrine.
-- Already applied to prod · via MCP 2026-07-08 (operator-approved this session).
-- Idempotent: cron.alter_job to fixed command text; re-apply is a no-op.
-- ============================================================================

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'refresh_movers_agg'),
  command := $cmd$SET statement_timeout='2700s';
SELECT set_config('app.movers_go', public.cron_should_fire('refresh_movers_agg')::text, false);
SELECT public.refresh_event_movers_agg(7)   WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(15)  WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(30)  WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(180) WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(365) WHERE current_setting('app.movers_go') = 'true';$cmd$);
