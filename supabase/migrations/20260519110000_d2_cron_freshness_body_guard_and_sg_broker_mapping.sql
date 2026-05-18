-- Migration 20260519110000 · lane:D2 (A1 to apply) · writes:d2_cron_freshness() · reads:cron.job,cron.job_run_details · pre:20260513230300_d2_cron_freshness_function · auth:operator-permitted 2026-05-19
--
-- Closes KANBAN B1-NEXT-1: add `current_user NOT IN` body guard (3rd
-- element of BOT_HIERARCHY.md §6). The prior fn was LANGUAGE sql so it
-- couldn't body-guard; this CREATE OR REPLACE converts to plpgsql with
-- the guard at the top.
--
-- Also folds in PR #147's pending intent: D2 dashboard's SG source was
-- swapped 2026-05-16 from seatgeek_orders (seller-side, dormant 400 rows)
-- to seatgeek_sales_snapshots (broker firehose, +67k/hr — see merged
-- PRs #147 + #158). The accompanying migration
-- (20260516200100_d2_cron_freshness_swap_sg_to_sg_sales.sql) was authored
-- but never apply_migration'd in prod, so the live fn still maps SG source
-- to sg_seller_orders_queue_30min instead of sg_broker_sales_queue_30min.
-- This mig consolidates both fixes into one apply step.
--
-- Closure: per PROJECT_BIBLE.md §1 rule #8, the B1-NEXT-1 row is DELETED
-- from KANBAN.md §🟢 OPEN WORK in the same PR.

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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, cron
AS $function$
BEGIN
  -- BOT_HIERARCHY.md §6 third element — defense in depth alongside
  -- REVOKE-from-PUBLIC + GRANT to service_role. Closes KANBAN B1-NEXT-1.
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
      -- 30-min process variant was unscheduled 2026-05-17 (PROJECT_BIBLE §4
      -- "bounded drain" note). The 1-min priority cron is the canonical
      -- drain — chip cadence differs but it IS what the operator should see.
      ('seatgeek_sales', 'sg_priority_sales_process_1min', 'process'),
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
END;
$function$;

REVOKE ALL ON FUNCTION public.d2_cron_freshness() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.d2_cron_freshness() TO service_role;

COMMENT ON FUNCTION public.d2_cron_freshness() IS
  'Per-source cron freshness for the D2 dashboard chips. SECDEF + body-guarded (B1-NEXT-1 closure). SG source maps to broker firehose crons (sg_broker_sales_queue_30min / _process_30min) post the 2026-05-16 dashboard rewire (PR #147/#158).';
