-- Migration 20260925233701 · level:secondary-sales · lane:D7 · writes:cron.job · reads:none · pre:20260925231959
--
-- Already applied to prod · via MCP 2026-09-25 under operator direction.
--
-- ============================================================================
-- Migration 20260925233701 — page 0 back on pg_net, direct fetch on a 50 s
-- timeout: run both paths, newest write wins
--
-- Lane: D7 · Pre-reqs: 20260925231959
--
-- 20260925231959 moved CRM page 0 off pg_net onto a synchronous 20 s fetch
-- with a 15 s curl timeout. In production every direct fetch timed out with
-- 0 bytes received, while pg_net pages 150/300 kept answering 200 — the CRM
-- does respond, it just takes longer than 15 s for a 150-row page. With page 0
-- no longer on pg_net, NO new order was ingested from 23:23:20 UTC until this
-- fix. The earlier "the CRM is not the slow part" reading was only half right:
-- part of the ~62 s pg_net wait is the CRM itself.
--
-- Fix (operator-approved):
--   * restore `PERFORM public.n2s_items_queue(150, 0);` in n2s_pipeline_tick,
--     so ingest can never again depend on the direct path alone;
--   * run the direct fetch with a 50 s curl timeout (statement_timeout 60 s).
-- Both paths write through n2s_items_upsert() (newer-wins on n2s_updated_at),
-- so running both is safe; whichever lands first ingests the order. The gate
-- (cron_should_fire) skips a 20 s tick while a slow fetch is still running.
-- ============================================================================

DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_pipeline_tick'::regproc);
  v_pat text := '-- page 0 is fetched directly every 20 s by n2s_crm_fetch_direct \(20260925231959\)[ \t]*\n?[ \t]*';
  v_hits int;
BEGIN
  SELECT count(*) INTO v_hits FROM regexp_matches(v_def, v_pat, 'g');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick: expected the 20260925231959 marker once, found %', v_hits;
  END IF;
  v_def := regexp_replace(v_def, v_pat,
    '-- page 0 also fetched directly by n2s_crm_fetch_direct (20260925233701); both paths share n2s_items_upsert' || E'\n    ' ||
    'PERFORM public.n2s_items_queue(150, 0);' || E'\n    ');
  EXECUTE v_def;
END $$;

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'n2s_crm_direct_20s'),
  command := $cmd$ SET statement_timeout = '60s'; SELECT public.n2s_crm_fetch_direct(150, 0, 50000); $cmd$
);
