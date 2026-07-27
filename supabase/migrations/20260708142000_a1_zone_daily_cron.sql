-- ============================================================================
-- Migration 20260708142000 — Daily build of the zone feature store
--
-- Lane:     data plane (A1)
-- Touches:  cron.job (new schedule; gated change, operator-approved 2026-07-08)
--
-- Runs build_zone_price_observations_day for today + yesterday at 07:00 UTC,
-- after the morning ESPN collects (team_daily standings 05:00, gamelog/stats/
-- attendance ~06:xx) so each day's row picks up fresh standings + realized
-- rosters. Yesterday is rebuilt too so late-arriving snapshots (final scores,
-- attendance, roster) land in that day's as-of row.
-- ============================================================================

SELECT cron.schedule(
  'zone_price_observations_daily',
  '0 7 * * *',
  $$
    SELECT public.build_zone_price_observations_day(current_date);
    SELECT public.build_zone_price_observations_day(current_date - 1);
  $$
);
