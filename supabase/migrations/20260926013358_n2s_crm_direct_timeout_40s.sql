-- Migration 20260926013358 · level:secondary-sales · lane:D7 · writes:cron.job · reads:none · pre:20260925233701
--
-- Already applied to prod · via MCP 2026-09-26 under operator direction.
--
-- ============================================================================
-- Migration 20260926013358 — direct CRM fetch: 40 s curl timeout
--
-- Lane: D7 · Pre-reqs: 20260925233701
--
-- With a 50 s curl timeout inside a 60 s statement_timeout, a slow CRM answer
-- plus the upsert regularly overran the statement: 21 of 88 runs since
-- 20260925233701 died as "canceling statement due to statement timeout",
-- which rolls back the run's n2s_crm_direct_log row, so those failures left no
-- trace in the log. At 40 s a slow CRM ends as a clean, LOGGED curl timeout
-- with ~20 s of headroom for the upsert. Successful fetches measured 35–50 s,
-- so a few that would have landed in 40–50 s now time out instead; pg_net page
-- 0 on the tick still covers them (both paths share n2s_items_upsert).
-- ============================================================================

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'n2s_crm_direct_20s'),
  command := $cmd$ SET statement_timeout = '60s'; SELECT public.n2s_crm_fetch_direct(150, 0, 40000); $cmd$
);
