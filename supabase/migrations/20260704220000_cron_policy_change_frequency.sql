-- Right-size the frequent ESPN cron intervals to each source's change
-- frequency, for efficiency (operator 2026-07-04: "use change frequency as the
-- base for crons").
--
-- Findings (cron.job_run_details, 24h): the daily jobs already fire exactly once
-- per day (attendance/stats/racing/mma) — optimal, left untouched. Only the
-- high-frequency jobs are worth tuning:
--   * espn-transactions-5min ~288 fires/day
--   * espn-gamelog-10min     ~144 fires/day
--   * espn-news-5min         ~288 fires/day
--
-- Change-frequency basis: US pro-sports transactions and box-score/game-log
-- updates cluster in active ET hours (roughly 9:00–00:00 ET for roster moves;
-- ~13:00–02:00 ET for game logs, i.e. day games through late West-coast
-- finals). Between ~01:00–08:00 ET the underlying data is effectively static, so
-- polling every few minutes overnight is pure waste. cron_should_fire already
-- supports this: it uses peak_min_interval_min inside peak_hours_et (ET) and
-- offpeak_min_interval_min outside. We keep the ACTIVE-hours cadence unchanged
-- (transactions still 5 min in-window, honoring the earlier "poll every 5 min"
-- directive) and stretch the dead overnight hours to 30 min.
--
-- News is left at 5 min around the clock: ESPN news is genuinely 24/7 (global
-- soccer, international events) and does not track US game hours.
-- cron_policy is a plain config table (not cron.*); this is operator-directed.

-- Transactions: active 09:00–00:00 ET at 5 min; 01:00–08:00 ET at 30 min.
UPDATE public.cron_policy SET
  peak_hours_et            = ARRAY[0,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
  peak_min_interval_min    = 5,
  offpeak_min_interval_min = 30,
  enabled                  = true,
  notes                    = 'ESPN transactions: 5-min in active ET hours (09:00–00:00), 30-min overnight (01:00–08:00). Change-frequency tuned 2026-07-04.',
  updated_at               = now()
WHERE jobname = 'espn-transactions-5min';

-- Game logs: active 13:00–02:00 ET at 8 min; 03:00–12:00 ET at 30 min.
UPDATE public.cron_policy SET
  peak_hours_et            = ARRAY[0,1,2,13,14,15,16,17,18,19,20,21,22,23],
  peak_min_interval_min    = 8,
  offpeak_min_interval_min = 30,
  enabled                  = true,
  notes                    = 'ESPN game logs: 8-min during/after games (13:00–02:00 ET), 30-min otherwise. Change-frequency tuned 2026-07-04.',
  updated_at               = now()
WHERE jobname = 'espn-gamelog-10min';

-- Daily sports aggregates already fire once/day (post-game / weekly sources) —
-- explicitly (re-)assert enabled so every pipeline is confirmed ON.
UPDATE public.cron_policy SET enabled = true, updated_at = now()
WHERE jobname IN ('espn-attendance-daily','espn-stats-daily','espn-racing-daily','espn-mma-daily','espn-news-5min');
