-- ============================================================================
-- Migration 20260704000200 — ESPN transactions: poll daily
--
-- Touches:  cron.job (W, via cron.schedule), cron_policy (W, one row)
-- Pre-reqs: espn-league-collect edge fn (?scope=transactions) deployed;
--           espn_transactions table (mig 20260704000000);
--           public._cron_invoke_edge_fn(text, jsonb), public.cron_should_fire(text),
--           public.cron_policy (all pre-existing).
--
-- WHY: league transactions are slow-moving aggregate data (a few roster moves
--   per league per day). A daily pull with change-tolerant dedup (onConflict
--   txn_key, ignoreDuplicates) accumulates the full ledger with no duplicates.
--   06:00 UTC — offset one hour after espn-team-daily (05:00) to spread load.
--
-- HOW: one edge-fn call fetches transactions for every distinct ESPN league
--   (~5 leagues, limit=100 each). cron_policy floor at 1380 min (23h) so a
--   once-daily cron always clears cron_should_fire()'s min-interval gate.
--
-- Read-only vs upstream: ESPN is a public GET data source (RULE 2 covers broker
--   listing/order APIs — N/A). No prod-data mutation here beyond cron/policy
--   registration; the apply itself is operator-gated.
-- ============================================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('espn-transactions-daily', '{}'::int[], 1380, 1380, NULL, 2, true,
   'ESPN league transactions once daily (espn-league-collect?scope=transactions). '
   '23h floor keeps the daily cron single-firing; append-only dedup on txn_key.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql           = EXCLUDED.work_check_sql,
  daily_max_fires          = EXCLUDED.daily_max_fires,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

SELECT cron.unschedule('espn-transactions-daily')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-transactions-daily');

SELECT cron.schedule(
  'espn-transactions-daily',
  '0 6 * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('espn-transactions-daily') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-league-collect?scope=transactions',
      '{}'::jsonb);
  END $body$;
  $cron$
);
