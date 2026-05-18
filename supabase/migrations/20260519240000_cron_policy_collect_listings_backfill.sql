-- 20260519240000_cron_policy_collect_listings_backfill.sql
--
-- Backfill `cron_policy` rows for the 5 collect-listings windowed crons.
-- Closes KANBAN.md B1-NEXT-37.
--
-- WHY:
--   All 5 crons currently produce `decision=fire_no_policy` in cron_gate_decisions
--   (default-fire behavior). Adds explicit daily_max_fires + interval limits so the
--   cron_should_fire gate has explicit ceilings to enforce.
--
-- CURRENT STATE (verified 2026-05-18):
--   collect-listings-0-24h    schedule "1-59/10 * * * *"   144 fires/24h
--   collect-listings-1-7d     schedule "30 5,17 * * *"       2 fires/24h
--   collect-listings-7-30d    schedule "20 4,16 * * *"       2 fires/24h
--   collect-listings-30-60d   schedule "35 4,16 * * *"       2 fires/24h
--   collect-listings-60d+     schedule "50 4,16 * * *"       2 fires/24h
--
-- DESIGN:
--   - daily_max_fires = ceil(actual + 10% safety margin)
--   - peak_min_interval_min matches schedule cadence (10 min for hot, 720 min for daily)
--   - work_check_sql left NULL — these crons are by-design "always sweep"; adding a
--     work check would be a separate behavior change.
--   - enabled=true (current behavior — no operational change).

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES
  ('collect-listings-0-24h',
   ARRAY[]::int[],          -- no peak distinction; runs every 10 min all day
   10, 10,
   NULL,
   150,                     -- 144 actual + safety margin
   true,
   'Hot window: events occurring 0-24h out. Sweeps every 10 min via */10 schedule. Policy ceiling 150/day.',
   now()),

  ('collect-listings-1-7d',
   ARRAY[]::int[],
   720, 720,                -- 12h interval matches twice-daily schedule (05:30 + 17:30)
   NULL,
   4,                       -- 2 actual + safety
   true,
   'Daily window: 1-7d horizon. Twice daily at 05:30 + 17:30 UTC.',
   now()),

  ('collect-listings-7-30d',
   ARRAY[]::int[],
   720, 720,
   NULL,
   4,
   true,
   'Daily window: 7-30d horizon. Twice daily at 04:20 + 16:20 UTC.',
   now()),

  ('collect-listings-30-60d',
   ARRAY[]::int[],
   720, 720,
   NULL,
   4,
   true,
   'Daily window: 30-60d horizon. Twice daily at 04:35 + 16:35 UTC.',
   now()),

  ('collect-listings-60d+',
   ARRAY[]::int[],
   720, 720,
   NULL,
   4,
   true,
   'Daily window: 60d+ horizon. Twice daily at 04:50 + 16:50 UTC.',
   now())
ON CONFLICT (jobname) DO NOTHING;

-- ============================================================
-- Post-apply verification
-- ============================================================
-- expected: 5 rows
--
-- SELECT jobname, peak_min_interval_min, daily_max_fires, enabled
-- FROM public.cron_policy
-- WHERE jobname LIKE 'collect-listings-%'
-- ORDER BY jobname;
--
-- expected: no rows (gate sees policy now)
-- SELECT jobname, decision, count(*)
-- FROM cron_gate_decisions
-- WHERE jobname LIKE 'collect-listings-%' AND decided_at > now() - interval '1 hour'
--   AND decision = 'fire_no_policy'
-- GROUP BY 1,2;
