-- ============================================================================
-- Migration 20260702143500 — mv_tevo_blindspot_movers: manual refresh + re-enable refresher
--
-- Lane:     A1
-- Touches:  REFRESH MATERIALIZED VIEW mv_tevo_blindspot_movers; cron.job 262
--           (tevo_blindspot_mv_refresh) re-activated.
-- Pre-reqs: 20260702033000 (Wizard data deletion), 20260701224500 (which
--           retired tevo_blindspot_metrics_refresh_12h).
--
-- WHY (operator 2026-07-02: "BLIND SPOTS — TEvo SELLING, WE'RE NOT still shows
-- wizard of oz"):
--   The Discovery-page panel reads mv_tevo_blindspot_movers via
--   get_blind_spots_tevo_selling(). The matview carried 229 stale Sphere Wizard
--   rows baked in from before the exclusion, because NOTHING was refreshing it:
--   mig 20260701224500 retired `tevo_blindspot_metrics_refresh_12h` as
--   "vestigial", but the dedicated `tevo_blindspot_mv_refresh` job (jobid 262,
--   the 10-min CONCURRENTLY refresher) was ALSO inactive — so the retirement
--   left the matview orphaned. That "vestigial" call was wrong in effect;
--   corrected here.
--
--   FIX:
--     1) One manual REFRESH — the underlying v_tevo_blindspot_movers already
--        excludes inactive events (event_lifecycle maps state='ignored' →
--        is_active=false) and requires latest_event_metrics rows (Wizard's are
--        deleted), so the refresh dropped all 229 rows (15 legit rows remain).
--     2) Re-enabled cron job `tevo_blindspot_mv_refresh` (schedule 7-59/10,
--        cron_should_fire-gated by its existing cron_policy row: 10-min peak /
--        30-min offpeak, daily cap 120). Its command keeps a plain
--        `SET statement_timeout='10min'` prefix — REFRESH CONCURRENTLY cannot
--        run inside a transaction block, so the BEGIN/SET LOCAL/COMMIT
--        leak-guard pattern (mig 20260702075500) does not apply to it.
--
-- Idempotent: REFRESH + alter_job(active:=true) — re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

REFRESH MATERIALIZED VIEW public.mv_tevo_blindspot_movers;

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname='tevo_blindspot_mv_refresh'),
  active := true);
