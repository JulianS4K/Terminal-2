-- Migration 20261113200000 · level:secondary-sales · lane:D7 · writes:cron:n2s_crm_direct_20s · reads:n2s_crm_direct_log · pre:20260927160500
--
-- CRM N2S FEED: read the first 500 items per poll instead of 150.
--
-- Operator 2026-11-13: "Expand to 500 fields instead of 150". The feed is sorted updated_at
-- DESC and every poll returned a full page (150 of 150 over 24 h), so anything past item 150
-- — a need2buy label or a sub decision on a quieter item included — was never read.
--
--   limit     150 -> 500, still one GET of page 0 every 30 seconds (RULE 2: read-only).
--   timeout   20 s -> 25 s. It must stay under the 30-second schedule. Over the last 24 h a
--             150-item fetch + upsert took 1.6 s at the median and 3 of 2,638 fetches failed.
--   watch     n2s_crm_direct_log (status, ms, items) after applying. If fetches start timing
--             out, roll back: a failed poll delays NEW orders for the N2S pipeline too.
--
-- The job name keeps its "_20s" suffix: cron_should_fire() and cron_policy are keyed on it.
--
-- rollback: SELECT cron.alter_job(jobid, command := 'SELECT public.n2s_crm_fetch_direct(150, 0, 20000);')
--           FROM cron.job WHERE jobname = 'n2s_crm_direct_20s';

DO $$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM cron.job WHERE jobname = 'n2s_crm_direct_20s';
  IF v_n <> 1 THEN
    RAISE NOTICE 'n2s_crm_direct_20s: % job(s) found, nothing changed', v_n;
    RETURN;
  END IF;
  PERFORM cron.alter_job(jobid, command := 'SELECT public.n2s_crm_fetch_direct(500, 0, 25000);')
     FROM cron.job WHERE jobname = 'n2s_crm_direct_20s';
END $$;
