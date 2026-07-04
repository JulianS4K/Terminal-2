-- ============================================================================
-- Migration 20260704000200 — ESPN transactions: poll every 5 minutes
--
-- Touches:  cron.job (W, via cron.schedule), cron_policy (W, one row)
-- Pre-reqs: espn-league-collect edge fn (?scope=transactions) deployed;
--           espn_transactions table (mig 20260704000000);
--           public._cron_invoke_edge_fn(text, jsonb), public.cron_should_fire(text),
--           public.cron_policy (all pre-existing).
--
-- WHY: operator directive (2026-07-04) — transactions feed the terminal NEWS WIRE
--   (mig 20260704020000) and must stay fresh, so poll every 5 min (was daily).
--   One edge-fn call fetches transactions for every distinct ESPN league
--   (~8 leagues, limit=100 each); change-tolerant dedup (onConflict txn_key,
--   ignoreDuplicates) makes a re-poll with no new moves a cheap no-op.
--
-- HOW: cron_policy floor at 4 min (NOT 5) so the */5 cron always clears the
--   cron_should_fire() min-interval gate despite tick jitter (same reasoning as
--   espn-news-5min, mig 20260702220000). No daily cap.
--
-- Read-only vs upstream: ESPN is a public GET data source (RULE 2 covers broker
--   listing/order APIs — N/A). No prod-data mutation here beyond cron/policy
--   registration; the apply itself is operator-gated.
-- ============================================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('espn-transactions-5min', '{}'::int[], 4, 4, NULL, NULL, true,
   'ESPN league transactions every 5 min (espn-league-collect?scope=transactions) '
   'for the NEWS WIRE. 4-min floor guarantees the */5 cron clears the gate; '
   'append-only dedup on txn_key makes no-op polls cheap.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql           = EXCLUDED.work_check_sql,
  daily_max_fires          = EXCLUDED.daily_max_fires,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

-- Retire the earlier daily variant if present, then (re)schedule the 5-min cron.
SELECT cron.unschedule('espn-transactions-daily')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-transactions-daily');
SELECT cron.unschedule('espn-transactions-5min')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-transactions-5min');

SELECT cron.schedule(
  'espn-transactions-5min',
  '*/5 * * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('espn-transactions-5min') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-league-collect?scope=transactions',
      '{}'::jsonb);
  END $body$;
  $cron$
);
