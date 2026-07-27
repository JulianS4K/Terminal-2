-- ============================================================================
-- Migration 20260702075500 — movers 840s budget + pg_cron SET-leak fix
--
-- Lane:     A1
-- Touches:  cron.job commands only (refresh_movers_agg,
--           sg_market_chart_rebuild_daily, sg_market_chart_reveal_pull_daily).
-- Pre-reqs: 20260701224500 (per-window movers split), 20260701213000 (900s role cap).
--
-- WHY (07:20 movers failure root-caused, 2026-07-02):
--   refresh_movers_agg failed 3 runs straight (06-30 19:20, 07-01 19:20,
--   07-02 07:20) with `canceling statement due to statement timeout` at ~120s —
--   yet its command carried NO SET prefix, the postgres role default is 900s,
--   and no role/db/function config anywhere says 120s.
--
--   ROOT CAUSE — **pg_cron SET leak** (new §3 landmine): with
--   use_background_workers=off, pg_cron runs jobs over PERSISTENT pooled libpq
--   connections. A multi-statement job command executes as one implicit
--   transaction; a plain `SET statement_timeout` inside it survives the commit
--   and STAYS ON THE CONNECTION — every later job that reuses that connection
--   inherits it. The only '120s' sources in the system are the two
--   sg_market_chart_* jobs; movers (prefix-less) kept landing on a polluted
--   connection and died at their 120s.
--
--   FIX (both directions):
--     1) refresh_movers_agg now carries its OWN explicit prefix
--        (`SET statement_timeout='840s';` — arms per-statement, under the 900s
--        role backstop; 5 window statements, worst case bounded). Self-defense:
--        a job that needs a non-trivial budget must never rely on inherited
--        session state.
--     2) The two chart jobs now use `BEGIN; SET LOCAL ...; ...; COMMIT;` —
--        SET LOCAL dies at COMMIT, so their 120s can no longer leak to other
--        jobs on the shared connection.
--
--   CONVENTION going forward: cron commands either carry their own SET prefix
--   (if they need > the smallest leaked budget in the fleet) or scope any SET
--   with BEGIN/SET LOCAL/COMMIT. Never rely on the role default alone —
--   126/138 active jobs are prefix-less and inherit whatever leaked last.
--
-- Idempotent: cron.alter_job to fixed command text; re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname='refresh_movers_agg'),
  command := $cmd$SET statement_timeout='840s';
SELECT set_config('app.movers_go', public.cron_should_fire('refresh_movers_agg')::text, false);
SELECT public.refresh_event_movers_agg(7)   WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(15)  WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(30)  WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(180) WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(365) WHERE current_setting('app.movers_go') = 'true';$cmd$);

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname='sg_market_chart_rebuild_daily'),
  command := $cmd$BEGIN; SET LOCAL statement_timeout='120s';
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_market_chart_rebuild_daily') THEN RETURN; END IF;
    PERFORM public.rebuild_sg_market_chart();
  END $body$; COMMIT;$cmd$);

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname='sg_market_chart_reveal_pull_daily'),
  command := $cmd$BEGIN; SET LOCAL statement_timeout='120s';
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_market_chart_reveal_pull_daily') THEN RETURN; END IF;
    PERFORM public.sg_market_chart_reveal_pull(400);
  END $body$; COMMIT;$cmd$);
