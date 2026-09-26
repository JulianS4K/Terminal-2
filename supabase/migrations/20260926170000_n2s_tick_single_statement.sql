-- Migration 20260926170000 · level:secondary-sales · lane:D7 · writes:cron.job · reads:none · pre:20260926144628
--
-- Already applied to prod · via MCP 2026-09-26 under operator direction, as a
-- 30-minute experiment, after a rolled-back dry run.
--
-- ============================================================================
-- Migration 20260926170000 — cron 640 (n2s_pipeline_tick) as ONE statement
--
-- Lane: D7 · Pre-reqs: 20260926144628
--
-- Finding (2026-09-26): pg_cron's single scheduler process dispatches the
-- whole project's jobs almost only in the instant after an N2S tick ends —
-- 91% of 2,596 job starts over 3 h were within 1 s of a tick's end_time, and
-- 81% of other long jobs record their end_time in the same second as a tick.
-- During a tick the launcher shows no wait event (not a lock; consistent with
-- a blocking read on a job connection). ~1,980 "job startup timeout" failures
-- a day project-wide; "20 seconds" jobs fire every 35–80 s.
--
-- The tick's command was two statements ('SET statement_timeout=240s;
-- SELECT n2s_pipeline_tick(200);'). pg_cron logs "COMMAND completed: SET" for
-- it and then appears to wait on the long SELECT. Another two-statement job
-- (tevo_blindspot_mv_refresh, 148 s) did NOT block, so this is a test, not a
-- proven cause.
--
-- The 240 s statement_timeout was a backstop only: the tick enforces its own
-- 200 s stage budget and a cron_try_lock overlap guard.
--
-- Baseline, 30 min before (16:30–17:00 UTC): 424 starts, 88.7% within 1 s of a
-- tick end; 43 startup timeouts; the '20 seconds' espn-rosters-rotate ran 32
-- times (90 expected); tick p50 49.7 s.
-- ============================================================================

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'n2s_pipeline_tick_1min'),
  command := 'SELECT public.n2s_pipeline_tick(200);'
);

-- rollback:
-- SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_pipeline_tick_1min'),
--   command := $c$ SET statement_timeout='240s'; SELECT public.n2s_pipeline_tick(200); $c$);
