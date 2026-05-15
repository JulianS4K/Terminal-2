-- Migration 20260515250002 · level:admin · lane:Audit/Push · writes:cron_policy work_check_sql + offpeak_min_interval for 3 ingest crons · pre:20260515250001
-- Operator directive 2026-05-14: "unfortunately max staleness should be 60 mins for sales"
-- Tightens the staleness floor from 4h/6h (set in 20260515250001) to 60min.
--
-- ## Already applied to prod  Applied via MCP 2026-05-14.

UPDATE public.cron_policy SET
  work_check_sql = regexp_replace(work_check_sql, 'interval ''4 hours''', 'interval ''60 minutes''', 'g'),
  notes = notes || ' [staleness floor tightened 4h->60min 2026-05-14]',
  updated_at = now()
WHERE jobname IN ('vivid_orders_queue_30min','tickpick_orders_queue_30min');

UPDATE public.cron_policy SET
  work_check_sql = regexp_replace(work_check_sql, 'interval ''6 hours''', 'interval ''60 minutes''', 'g'),
  notes = notes || ' [staleness floor tightened 6h->60min 2026-05-14]',
  updated_at = now()
WHERE jobname = 'evo_orders_queue_30min';

UPDATE public.cron_policy SET
  offpeak_min_interval_min = LEAST(offpeak_min_interval_min, 60)
WHERE jobname IN ('vivid_orders_queue_30min','tickpick_orders_queue_30min','evo_orders_queue_30min');
