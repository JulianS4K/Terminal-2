-- Migration 20260514210000 · level:admin · lane:Audit/Push · writes:cron.alter_job (schedule) for 64 jobs · reads:- · pre:20260514190000
-- Cron hierarchy enforcement per CRON_HIERARCHY.md (new in this PR).
--
-- Operator directive 2026-05-14: "create a cron/data hierarchy so we can
-- maximize data freshness without killing out available resources and
-- allow for future projects like b1-4 to use resources."
--
-- Tiers + minute staggering keep peak concurrent ≤ 20 (out of 32 worker
-- pool), reserving 12+ workers for future bots (B2-B4) and manual ops.
--
-- T0 (2 jobs, every 10 min)      — storefront-critical matview refresh
-- T1 (10 jobs, every 10-20 min)  — near-live ingest (current-day listings, gameday scoreboards)
-- T2 (30 jobs, every 30 min)     — staggered offsets 0-29 across the 30-min window
--    + 7 hourly jobs at minutes 16,18,20,22,24,26,28
-- T3 (22 jobs, daily 03:00-05:59 UTC) — sweeps, catchups, window backfills
-- T4 (8 jobs, Sunday 04:00-05:59 UTC) — tournament + climatology
--
-- Jobs 38 (master-cascade-2min) and 98 (zone-backfill-isolated-10min) are
-- intentionally NOT touched here — they remain paused pending operator
-- decision on the row 65 advisor flag.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 ~19:30 UTC. Idempotent (same-value
-- alter_job is no-op).

DO $$ BEGIN
  -- T0: storefront-critical (every 10 min, max 4)
  PERFORM cron.alter_job(job_id := 91,  schedule := '8 * * * *');
  PERFORM cron.alter_job(job_id := 124, schedule := '2-59/10 * * * *');

  -- T1: near-live ingest (every 10-20 min, max 10)
  PERFORM cron.alter_job(job_id := 53,  schedule := '*/20 * * * *');
  PERFORM cron.alter_job(job_id := 108, schedule := '1-59/20 * * * *');
  PERFORM cron.alter_job(job_id := 58,  schedule := '3-59/15 * * * *');
  PERFORM cron.alter_job(job_id := 128, schedule := '*/10 * * * *');
  PERFORM cron.alter_job(job_id := 129, schedule := '5-59/10 * * * *');
  PERFORM cron.alter_job(job_id := 100, schedule := '7-59/15 * * * *');
  PERFORM cron.alter_job(job_id := 71,  schedule := '*/15 * * * *');
  PERFORM cron.alter_job(job_id := 72,  schedule := '5-59/15 * * * *');
  PERFORM cron.alter_job(job_id := 92,  schedule := '9 * * * *');
  PERFORM cron.alter_job(job_id := 74,  schedule := '11-59/15 * * * *');

  -- T2: standard ingest (every 30 min, staggered)
  PERFORM cron.alter_job(job_id := 61,  schedule := '0,30 * * * *');
  PERFORM cron.alter_job(job_id := 62,  schedule := '5,35 * * * *');
  PERFORM cron.alter_job(job_id := 63,  schedule := '2,32 * * * *');
  PERFORM cron.alter_job(job_id := 64,  schedule := '4,34 * * * *');
  PERFORM cron.alter_job(job_id := 65,  schedule := '7,37 * * * *');
  PERFORM cron.alter_job(job_id := 68,  schedule := '9,39 * * * *');
  PERFORM cron.alter_job(job_id := 120, schedule := '11,41 * * * *');
  PERFORM cron.alter_job(job_id := 126, schedule := '13,43 * * * *');
  PERFORM cron.alter_job(job_id := 127, schedule := '15,45 * * * *');
  PERFORM cron.alter_job(job_id := 43,  schedule := '17,47 * * * *');
  PERFORM cron.alter_job(job_id := 44,  schedule := '19,49 * * * *');
  PERFORM cron.alter_job(job_id := 45,  schedule := '21,51 * * * *');
  PERFORM cron.alter_job(job_id := 46,  schedule := '23,53 * * * *');
  PERFORM cron.alter_job(job_id := 47,  schedule := '25,55 * * * *');
  PERFORM cron.alter_job(job_id := 48,  schedule := '27,57 * * * *');
  PERFORM cron.alter_job(job_id := 49,  schedule := '29,59 * * * *');
  PERFORM cron.alter_job(job_id := 93,  schedule := '1,31 * * * *');
  PERFORM cron.alter_job(job_id := 94,  schedule := '3,33 * * * *');
  PERFORM cron.alter_job(job_id := 104, schedule := '6,36 * * * *');
  PERFORM cron.alter_job(job_id := 105, schedule := '8,38 * * * *');
  PERFORM cron.alter_job(job_id := 106, schedule := '10,40 * * * *');
  PERFORM cron.alter_job(job_id := 107, schedule := '12,42 * * * *');
  PERFORM cron.alter_job(job_id := 101, schedule := '14,44 * * * *');
  -- Hourly slots :16-:28
  PERFORM cron.alter_job(job_id := 117, schedule := '16 * * * *');
  PERFORM cron.alter_job(job_id := 118, schedule := '18 * * * *');
  PERFORM cron.alter_job(job_id := 114, schedule := '20 * * * *');
  PERFORM cron.alter_job(job_id := 70,  schedule := '22 * * * *');
  PERFORM cron.alter_job(job_id := 20,  schedule := '24 * * * *');
  PERFORM cron.alter_job(job_id := 21,  schedule := '26 * * * *');
  PERFORM cron.alter_job(job_id := 29,  schedule := '28 * * * *');

  -- T3: daily 03:00-05:59 UTC
  PERFORM cron.alter_job(job_id := 6,   schedule := '0 3 * * *');
  PERFORM cron.alter_job(job_id := 18,  schedule := '5 3 * * *');
  PERFORM cron.alter_job(job_id := 27,  schedule := '10 3 * * *');
  PERFORM cron.alter_job(job_id := 34,  schedule := '15 3 * * *');
  PERFORM cron.alter_job(job_id := 36,  schedule := '20 3 * * *');
  PERFORM cron.alter_job(job_id := 69,  schedule := '25 3 * * *');
  PERFORM cron.alter_job(job_id := 73,  schedule := '30 3 * * *');
  PERFORM cron.alter_job(job_id := 84,  schedule := '35 3 * * *');
  PERFORM cron.alter_job(job_id := 95,  schedule := '40 3 * * *');
  PERFORM cron.alter_job(job_id := 90,  schedule := '45 3 * * *');
  PERFORM cron.alter_job(job_id := 102, schedule := '50 3 * * *');
  PERFORM cron.alter_job(job_id := 103, schedule := '55 3 * * *');
  PERFORM cron.alter_job(job_id := 99,  schedule := '0 4 * * *');
  PERFORM cron.alter_job(job_id := 55,  schedule := '15 4 * * *');
  PERFORM cron.alter_job(job_id := 110, schedule := '20 4 * * *');
  PERFORM cron.alter_job(job_id := 56,  schedule := '30 4 * * *');
  PERFORM cron.alter_job(job_id := 111, schedule := '35 4 * * *');
  PERFORM cron.alter_job(job_id := 57,  schedule := '45 4 * * *');
  PERFORM cron.alter_job(job_id := 112, schedule := '50 4 * * *');
  PERFORM cron.alter_job(job_id := 113, schedule := '0 5 * * *');
  PERFORM cron.alter_job(job_id := 54,  schedule := '15 5 * * *');
  PERFORM cron.alter_job(job_id := 109, schedule := '30 5 * * *');

  -- T4: weekly Sunday 04:00-05:59 UTC
  PERFORM cron.alter_job(job_id := 50,  schedule := '0 4 * * 0');
  PERFORM cron.alter_job(job_id := 80,  schedule := '10 4 * * 0');
  PERFORM cron.alter_job(job_id := 81,  schedule := '20 4 * * 0');
  PERFORM cron.alter_job(job_id := 82,  schedule := '30 4 * * 0');
  PERFORM cron.alter_job(job_id := 83,  schedule := '40 4 * * 0');
  PERFORM cron.alter_job(job_id := 88,  schedule := '0 5 * * 0');
  PERFORM cron.alter_job(job_id := 96,  schedule := '10 5 * * 0');
  PERFORM cron.alter_job(job_id := 97,  schedule := '20 5 * * 0');
END $$;

-- Resume all jobs except the row-65 advisor items (38, 98)
DO $$ BEGIN
  PERFORM cron.alter_job(job_id := jobid, active := true)
  FROM cron.job
  WHERE NOT active AND jobid NOT IN (38, 98);
END $$;
