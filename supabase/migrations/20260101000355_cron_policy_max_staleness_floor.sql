-- Migration 20260515250001 · level:admin · lane:Audit/Push · writes:cron_policy.work_check_sql for 3 ingest crons · reads:- · pre:20260515250000
-- Max-staleness floor for ingest cron work-checks.
--
-- Operator question 2026-05-14: "how do you know when there's no work?"
-- Honest answer: for SWEEP crons the work-check is directly verifiable
-- (EXISTS query on the predicate the sweep would scan). For INGEST crons
-- it's a HEURISTIC — we can't see upstream API state without firing.
--
-- Failure mode the heuristic can hit: if a cron stays paused for >24h,
-- local max(ordered_at) becomes stale, the heuristic keeps reporting "no
-- recent activity" forever, the cron never fires, data ages indefinitely.
--
-- Fix: add a "fire at least every N hours regardless" override clause
-- to each ingest work-check. This bounds the worst-case staleness from
-- "unbounded" to N hours.
--
-- Per-cron N values:
--   Vivid/TickPick:  4h floor   (retail surfaces; daytime activity)
--   Evo:             6h floor   (B2B; lower cadence acceptable)
--
-- The OR clause coalesces cron_last_fire() to 1970 so the very first fire
-- on a fresh DB also passes (NULL < anything would be NULL otherwise).
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14. Idempotent UPDATE — re-running is a no-op
-- when values already match.

UPDATE public.cron_policy SET
  work_check_sql = $cs$
    SELECT
      (SELECT max(ordered_at) FROM public.vivid_orders)
        > coalesce(public.cron_last_fire('vivid_orders_queue_30min'),
                   '1970-01-01'::timestamptz) - interval '24 hours'
      OR coalesce(public.cron_last_fire('vivid_orders_queue_30min'),
                  '1970-01-01'::timestamptz) < now() - interval '4 hours'
  $cs$,
  notes = 'Retail peak 8 AM + 2 PM ET; 24h activity heuristic + 4h max-staleness floor',
  updated_at = now()
WHERE jobname = 'vivid_orders_queue_30min';

UPDATE public.cron_policy SET
  work_check_sql = $cs$
    SELECT
      (SELECT max(ordered_at) FROM public.tickpick_orders)
        > coalesce(public.cron_last_fire('tickpick_orders_queue_30min'),
                   '1970-01-01'::timestamptz) - interval '24 hours'
      OR coalesce(public.cron_last_fire('tickpick_orders_queue_30min'),
                  '1970-01-01'::timestamptz) < now() - interval '4 hours'
  $cs$,
  notes = 'Daytime peak ~4 PM ET; 24h activity heuristic + 4h max-staleness floor',
  updated_at = now()
WHERE jobname = 'tickpick_orders_queue_30min';

UPDATE public.cron_policy SET
  work_check_sql = $cs$
    SELECT
      (SELECT max(evo_created_at) FROM public.evo_orders)
        > coalesce(public.cron_last_fire('evo_orders_queue_30min'),
                   '1970-01-01'::timestamptz) - interval '24 hours'
      OR coalesce(public.cron_last_fire('evo_orders_queue_30min'),
                  '1970-01-01'::timestamptz) < now() - interval '6 hours'
  $cs$,
  notes = 'B2B inventory ops; spread 10 AM-9 PM ET; 24h activity heuristic + 6h max-staleness floor',
  updated_at = now()
WHERE jobname = 'evo_orders_queue_30min';
