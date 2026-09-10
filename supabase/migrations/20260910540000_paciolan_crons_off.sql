-- ============================================================================
-- Migration 20260910540000 — stop the Paciolan crons (closes A1-OPS-32)
--
-- Lane: A1 (the surface D6 folded into 2026-09-10) · Level: Applier
-- Operator 2026-09-10: "turn off pac crons."
--
-- Both jobs have been firing on schedule against a pipeline that has never held
-- a single row: paciolan_seat_snapshots 0, paciolan_pull_queue 0, raw captures
-- 0 — the Chrome collector was never run. 532 fires every 5 minutes (288/day),
-- 533 hourly (24/day); this stops 312 no-op runs a day.
--
-- ⚠ DEACTIVATED, NOT UNSCHEDULED, AND NOTHING IS DROPPED. cron.alter_job with
-- active := false leaves both definitions intact, so re-enabling is one
-- statement rather than a reconstruction. The paciolan_* schema, the client,
-- the Chrome extension and routers/paciolan.py all stay exactly as they are:
-- the code is complete and reviewed, so igniting this later is a collector run,
-- not a rebuild. Do NOT "tidy up" by dropping the schema on the strength of
-- this migration.
--
-- To restore: SELECT cron.alter_job(532, active := true); and the same for 533.
-- ============================================================================

SELECT cron.alter_job(532, active := false);
SELECT cron.alter_job(533, active := false);
