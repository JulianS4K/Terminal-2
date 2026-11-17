-- Migration 20260901174500 · level:secondary-sales · lane:D0 · writes:none · reads:cron.job,cron.job_run_details · pre:20260901180000
--
-- Add the S4K CRM ingest to d2_cron_freshness()'s per-source map.
--
-- WHY. The orders surface renders a "last pull: Nm ago · every 10m" chip per
-- source from this function. Adding `s4kcs` to `_ALL_SOURCES` in
-- core/d0_orders.py without this leaves the new tile with a blank freshness
-- chip — the rows show, but there's no way to tell whether the feed is live
-- or stalled, which is the one thing that chip exists to answer.
--
-- SCOPE. Two mapping rows. The caller assert and the queue/process shape are
-- byte-identical to the deployed body; nothing else changes and no caller
-- gains access (service_role only, as before).
--
-- NOTE on the timestamp: this sorts BEFORE 20260901180000, which creates the
-- crons it maps. That is safe — the mapping LEFT JOINs cron.job, so a name
-- that doesn't exist yet yields NULL schedule/active rather than an error,
-- and the migrations-from-zero replay stays green either way.

CREATE OR REPLACE FUNCTION public.d2_cron_freshness()
RETURNS TABLE(source text, jobname text, phase text, schedule text, active boolean,
              last_run timestamptz, last_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, cron
AS $$
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'd2_cron_freshness: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH mapping(source, jobname, phase) AS (
    VALUES
      ('evo',            'evo_orders_queue_30min',         'queue'),
      ('evo',            'evo_orders_process_30min',       'process'),
      ('seatgeek_sales', 'sg_broker_sales_queue_30min',    'queue'),
      ('seatgeek_sales', 'sg_priority_sales_process_1min', 'process'),
      ('tickpick',       'tickpick_orders_queue_30min',    'queue'),
      ('tickpick',       'tickpick_orders_process_30min',  'process'),
      ('s4kcs',          's4kcs_orders_queue_10min',       'queue'),
      ('s4kcs',          's4kcs_orders_process_10min',     'process')
  )
  SELECT
    m.source, m.jobname, m.phase, j.schedule, j.active,
    (SELECT max(d.start_time) FROM cron.job_run_details d WHERE d.jobid = j.jobid) AS last_run,
    (SELECT d.status FROM cron.job_run_details d WHERE d.jobid = j.jobid ORDER BY d.start_time DESC LIMIT 1) AS last_status
  FROM mapping m
  LEFT JOIN cron.job j ON j.jobname = m.jobname;
END;
$$;

REVOKE ALL ON FUNCTION public.d2_cron_freshness() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.d2_cron_freshness() TO service_role;
