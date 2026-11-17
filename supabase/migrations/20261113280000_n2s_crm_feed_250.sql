-- Migration 20261113280000 · level:secondary-sales · lane:D7 · writes:cron:n2s_crm_direct_20s · reads:n2s_crm_direct_log · pre:20261113200000
--
-- CRM N2S FEED: read the first 250 items per poll (was 500).
--
-- Operator 2026-11-13: "change poller to 250". At 500 items (mig 20261113200000) no poll
-- failed, but over 6 hours 40% of polls took more than 30 seconds (about 10-13% at 150) and
-- only 486 of 720 scheduled polls ran, so new orders reached the N2S pipeline later.
-- 250 keeps most of the extra reach at less of that cost. Timeout stays 25 s.
--
-- rollback: SELECT cron.alter_job(jobid, command := 'SELECT public.n2s_crm_fetch_direct(500, 0, 25000);')
--           FROM cron.job WHERE jobname = 'n2s_crm_direct_20s';

DO $$
BEGIN
  IF to_regclass('cron.job') IS NULL THEN RETURN; END IF;                     -- no pg_cron here (local / CI)
  EXECUTE $q$
    SELECT cron.alter_job(jobid, command := 'SELECT public.n2s_crm_fetch_direct(250, 0, 25000);')
      FROM cron.job WHERE jobname = 'n2s_crm_direct_20s'
  $q$;
END $$;
