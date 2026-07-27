-- Migration 20260516200100 · lane:D2 · writes:d2_cron_freshness() · reads:cron.job,cron.job_run_details · pre:20260513230300,20260516200000 · auth:operator-permitted 2026-05-16
-- Swap dashboard SG cron mapping from sg_seller_orders_* (seller-side polling
-- of dormant account) → sg_broker_sales_* (broker firehose, the live signal).
-- Source key renamed 'seatgeek' → 'seatgeek_sales' to match unified_orders
-- branch + d2_metrics_*() RPC source filter post-2026-05-16 rewire.

CREATE OR REPLACE FUNCTION public.d2_cron_freshness()
RETURNS TABLE(
  source       text,
  jobname      text,
  phase        text,
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
    ('evo',            'evo_orders_queue_30min',         'queue'),
    ('evo',            'evo_orders_process_30min',       'process'),
    ('seatgeek_sales', 'sg_broker_sales_queue_30min',    'queue'),
    ('seatgeek_sales', 'sg_broker_sales_process_30min',  'process'),
    ('tickpick',       'tickpick_orders_queue_30min',    'queue'),
    ('tickpick',       'tickpick_orders_process_30min',  'process')
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
