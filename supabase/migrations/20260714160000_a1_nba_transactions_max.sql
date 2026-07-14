-- ============================================================================
-- Migration 20260714160000 — Poll ESPN transactions at max cadence (1 min)
--
-- Lane:     A1 data plane (cron cadence only)
-- Touches:  cron.job (reschedule espn-transactions-5min → every minute),
--           cron_policy (lower the per-fire floor to 1 min)
-- Pre-reqs: 20260704000000 (espn_transactions), espn-league-collect?scope=transactions
--
-- WHY: operator wants NBA transactions polled at max. espn-league-collect's
--   ?scope=transactions pull is ONE lightweight edge call covering every league
--   in a single request (no per-league param), so maxing the whole job maxes NBA
--   with no extra fan-out. Bumped 5 min → 1 min; the cron_should_fire() floor is
--   lowered to 1 so every tick clears the gate. (Transactions are low-volume, so
--   most 1-min pulls upsert nothing — the tweet_id-style PK dedupes; the cost is
--   one cheap GET/min.) The jobname keeps its historical '-5min' suffix so the
--   cron_should_fire('espn-transactions-5min') arg in the body stays valid.
-- ============================================================================

SELECT cron.schedule(
  'espn-transactions-5min',
  '* * * * *',
  $cron$
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('espn-transactions-5min') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-league-collect?scope=transactions',
      '{}'::jsonb);
  END $body$;
  $cron$
);

UPDATE public.cron_policy
   SET peak_min_interval_min    = 1,
       offpeak_min_interval_min = 1,
       notes = 'ESPN transactions — MAX cadence (1 min, operator 2026-07-14). One '
               'all-league edge call per fire; cron_should_fire floor = 1 min.',
       updated_at = now()
 WHERE jobname = 'espn-transactions-5min';
