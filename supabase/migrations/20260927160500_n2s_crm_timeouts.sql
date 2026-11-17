-- Migration 20260927160500 · level:secondary-sales · lane:D7 · writes:n2s_items_queue,cron.job · reads:none · pre:20260927045900
--
-- Already applied to prod · via MCP 2026-09-27 16:05 UTC under operator direction
-- ("Do it"), after a rolled-back dry run (a real direct fetch at 20 s: 200, 150
-- items, 1.8 s).
--
-- ============================================================================
-- CRM requests are bimodal: fast, or they hang to our timeout (~1 in 4, both
-- paths, every hour — CRM side). With page 0 only (20260927030000), good
-- responses take ~6–8 s (p90 ~25 s), so the long timeouts only made each hang
-- expensive — and the tick's 60 s pg_net request held back the whole pg_net
-- batch, so N2S marketplace responses (20260927045900) became visible late.
--   * direct fetch (job 660): every 30 s, 20 s timeout, single-statement command
--   * tick pg_net CRM request: 25 s timeout (was 60 s)
-- RESULT (first 90 min): direct fetch 93 % ok (was ~73 %), ok p50 1.9 s,
-- p90 7.5 s; marketplace fire→land 36–51 s (was 30–70 s).
-- ============================================================================

DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_items_queue'::regproc);
  v_old text := 'timeout_milliseconds := 60000';
BEGIN
  IF md5(v_def) <> '32f78044ad49b1196f77b76d3d4b27d6' THEN RAISE EXCEPTION 'n2s_items_queue drifted — refusing'; END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN RAISE EXCEPTION 'n2s_items_queue: timeout anchor not found exactly once'; END IF;
  EXECUTE replace(v_def, v_old, 'timeout_milliseconds := 25000');
  PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_crm_direct_20s'),
                         schedule := '30 seconds',
                         command := 'SELECT public.n2s_crm_fetch_direct(150, 0, 20000);');
END $$;

-- rollback: timeout_milliseconds := 60000 in n2s_items_queue; job 660 back to
-- schedule '* * * * *', command $c$ SET statement_timeout = '60s'; SELECT public.n2s_crm_fetch_direct(150, 0, 40000); $c$.
