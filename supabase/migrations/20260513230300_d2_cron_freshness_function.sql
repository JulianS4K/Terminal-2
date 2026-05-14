-- SECURITY DEFINER function that surfaces cron freshness per d2_dashboard
-- source. Anon/authenticated can't read cron.* directly (postgres role
-- restriction); this function lets the dashboard's service_role client
-- pull a flat per-source view.
--
-- Returns one row per source/cron-job — sources with multiple jobs
-- (queue + process) get multiple rows; the dashboard picks the
-- queue-phase row as the canonical "when did this last fire."
--
-- Hardened with REVOKE ALL FROM anon/authenticated + EXECUTE only to
-- service_role per the 2026-05-13 secdef lockdown (PR #90 / migration
-- 20260513194124).

CREATE OR REPLACE FUNCTION public.d2_cron_freshness()
RETURNS TABLE(
  source       text,
  jobname      text,
  phase        text,        -- 'queue' | 'process' | 'other'
  schedule     text,
  active       boolean,
  last_run     timestamptz,
  last_status  text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, cron
AS $$
WITH mapping(source, jobname, phase) AS (
  VALUES
    ('evo',      'evo_orders_queue_30min',      'queue'),
    ('evo',      'evo_orders_process_30min',   'process'),
    ('seatgeek', 'sg_seller_orders_queue_30min','queue'),
    ('seatgeek', 'sg_seller_process_30min',     'process'),
    ('tickpick', 'tickpick_orders_queue_30min', 'queue'),
    ('tickpick', 'tickpick_orders_process_30min','process')
)
SELECT
  m.source,
  m.jobname,
  m.phase,
  j.schedule,
  j.active,
  (SELECT max(d.start_time) FROM cron.job_run_details d WHERE d.jobid = j.jobid) AS last_run,
  (SELECT d.status FROM cron.job_run_details d WHERE d.jobid = j.jobid ORDER BY d.start_time DESC LIMIT 1) AS last_status
FROM mapping m
LEFT JOIN cron.job j ON j.jobname = m.jobname;
$$;

REVOKE ALL ON FUNCTION public.d2_cron_freshness() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2_cron_freshness() TO service_role;
