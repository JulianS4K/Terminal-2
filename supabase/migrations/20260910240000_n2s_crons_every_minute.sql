-- ============================================================================
-- Migration 20260910240000 — run the N2S pipeline every minute
--
-- Lane:     D0 (orders surface)
-- Touches:  the SCHEDULE of cron jobs 595-604 (N2S pipeline). No command text,
--           no function, no table is changed.
-- Pre-reqs: none (guarded; these jobs are scheduled by hand, not by migrations)
--
-- READ-ONLY upstream: cadence only. Every request these jobs make was already
-- a GET and still is. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "change n2s cron at every 1 min".
--
-- ── SAFE BECAUSE MEASURED, NOT ASSUMED ────────────────────────────────────
-- A job that runs longer than its interval overlaps itself. Runtimes over the
-- preceding 2 hours (60 runs each, 24 for the 5-minute one):
--     598 n2s_map_events          avg 6.1s  max 8.7s
--     602 n2s_cover_queue_refresh avg 1.9s  max 6.4s
--     597 n2s_sub_ping            avg 1.9s  max 6.4s
--     599 n2s_td_enqueue          avg 1.8s  max 4.0s
--     603 n2s_pull_all_sources    avg 0.1s  max 1.8s
--     604 sg_listings_process     avg 0.1s  max 1.5s
--     596 n2s_items_drain         avg 0.3s  max 1.0s
--     601 n2s_td_drain            avg 0.4s  max 0.8s
--     595 n2s_items_sync          avg 0.2s  max 0.7s
-- The worst case is 8.7s against a 60s window — 7x headroom.
--
-- ⚠ THIS COLLAPSES THE EVEN/ODD OFFSET, AND THAT IS FINE. The pipeline was
-- built with requests firing on even minutes (*/2) and responses read on odd
-- ones (1-59/2), because pg_net is asynchronous with 1-3 minutes of latency.
-- At a 1-minute cadence both run every tick. That costs nothing: a drain reads
-- whatever has LANDED and leaves the rest for the next tick, so a response
-- still waits at most one tick — the same as before — while everything that
-- has already arrived is processed a minute sooner. The offset was never a
-- correctness constraint; it was a way to avoid a pointless read.
--
-- ⚠ THE SPEND GUARDS ARE WHAT MAKE THIS SAFE, AND NONE OF THEM IS TOUCHED:
--   * n2s_items_queue refuses to fire when >= 9 requests are already in flight
--     (p_max_inflight, mig 20260910040000), so doubling the tick rate cannot
--     pile up on the CRM — it just skips.
--   * n2s_td_enqueue/drain stay bounded by td_budget_ok() and the 500/day cap.
--     Enqueueing more often does NOT spend more; the cap is the cap.
--   * n2s_pull_all_sources is gated per order by sources_pulled_at, so each
--     order's four-source pull happens once no matter how often the job runs.
-- Never raise the cadence again without re-checking those three.
--
-- ⚠ THE JOB NAMES NOW LIE. They still read "…_2min" because pg_cron cannot
-- rename a job in place: renaming means unschedule + re-schedule, which would
-- discard the run history AND force the command text to be re-supplied — and
-- that text lives in no migration (these jobs were created by hand). Trading a
-- correct name for a chance to mistype a command is a bad trade; this session
-- has already broken the CRM ingest once doing exactly that. Read the schedule
-- column, not the name.
-- ============================================================================

DO $recadence$
DECLARE
  r RECORD;
  v_n integer := 0;
BEGIN
  FOR r IN
    SELECT jobid, jobname FROM cron.job
     WHERE jobname IN ('n2s_items_sync_2min', 'n2s_items_drain_2min',
                       'n2s_sub_ping_2min', 'n2s_map_events_5min',
                       'n2s_td_enqueue_2min', 'n2s_td_drain_2min',
                       'n2s_cover_queue_refresh_2min',
                       'n2s_pull_all_sources_2min',
                       'sg_listings_process_on_demand_2min')
       AND schedule <> '* * * * *'
  LOOP
    -- schedule ONLY. alter_job leaves command, database and username alone,
    -- so nothing has to be retyped.
    PERFORM cron.alter_job(r.jobid, schedule := '* * * * *');
    RAISE NOTICE 'n2s cadence: % (jobid %) -> every minute', r.jobname, r.jobid;
    v_n := v_n + 1;
  END LOOP;

  IF v_n = 0 THEN
    -- Fresh database (the jobs are created by hand, so a replay has none), or
    -- already applied. Say so rather than implying work happened.
    RAISE NOTICE 'n2s cadence: no jobs needed re-scheduling';
  END IF;
END
$recadence$;
