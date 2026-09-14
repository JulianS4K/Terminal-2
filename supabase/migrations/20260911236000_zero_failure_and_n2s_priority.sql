-- ============================================================================
-- Migration 20260911236000 — drive the cron failure rate to zero, N2S first in line
-- Migration 20260911236000 · level:data-collection · lane:A1 · writes:cron.job,cron_policy · reads:cron.job_run_details · pre:20260911230050,20260911232000,20260911233000,20260911234000,20260911235500
--
-- Lane:     A1 (crons)
-- Touches:  cron.job (W), cron_policy (W)
--
-- Failure inventory, last 6 hours, ~180 failed runs in three families:
--
--   ~130  "job startup timeout"                    slot exhaustion
--     31  "deadlock detected"                      gt_ingest vs gt_deals_scan
--     11  "canceling statement due to statement timeout"
--
-- The deadlocks are already fixed (20260911233000, shared advisory lock). This
-- migration closes the other two.
--
-- ── 1. STARTUP TIMEOUTS ARE A CAPACITY PROBLEM, NOT A JOB PROBLEM ──────────
-- pg_cron raises "job startup timeout" when a job cannot get a worker:
-- max_running_jobs=32, use_background_workers=off, so every running job holds a
-- backend. The jobs named in those failures are victims, not causes — which is
-- why there is nothing to fix in any of them individually.
--
-- Load removed by this PR's other migrations, in continuously-occupied slots
-- (measured from 6h of cron.job_run_details):
--   TD (25 jobs, 435 slot-min/6h)                        ~1.2 slots
--   wiki (2x pww @ 38.5s mean on '* * * * *', + 6 more)  ~1.3 slots
--   health_monitor_5min (118.8s mean / 300s)             ~0.4 slots
--   n2s 6 crons -> 1 ordered tick                        ~2.2 slots
--                                                  total ~5.1 of ~8.1 average
--
-- That is the fix for the startup timeouts. What remains here is to stop the
-- survivors from re-colliding on the same minute marks.
--
-- ── 2. N2S GETS FIRST CALL ON THE SCHEDULER ───────────────────────────────
-- pg_cron has no priority mechanism, so priority has to be built from what it
-- does offer: n2s_pipeline_tick_1min runs every minute and is the one job that
-- must never be starved. Three things protect it, in order of strength:
--
--   (a) Headroom. The ~5.1 slots above are the real protection.
--   (b) Exclusive minute-mark. Every OTHER sub-hourly job is moved off the
--       :00-of-minute alignment where possible, so the n2s tick is not
--       competing for a worker at the instant it fires.
--   (c) Harmless misses. n2s_pipeline_tick holds an xact advisory lock and is
--       internally wall-clock bounded, so a skipped start costs one minute and
--       never corrupts state — the next tick resumes the same ordered chain.
--
-- N2S is deliberately the ONLY sub-minute job left ungated by cron_policy.
--
-- ── 3. THE THREE REAL STATEMENT TIMEOUTS ──────────────────────────────────
-- These are genuine: the work does not fit the limit it was given.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 3a. tevo_blindspot_mv_refresh — 8 of the 11 timeouts
--
-- REFRESH MATERIALIZED VIEW against a 10-minute statement_timeout, at a
-- measured 132s mean and 663s max. 20260911234000 already moved it to 30-min
-- at peak; the timeout itself still needs to exceed the observed maximum or it
-- will keep dying on the long tail. 20 minutes, and off the :07 mark.
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('tevo_blindspot_mv_refresh')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tevo_blindspot_mv_refresh');

SELECT cron.schedule(
  'tevo_blindspot_mv_refresh',
  '9-59/10 * * * *',
  $cron$ SET statement_timeout = '20min';
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('tevo_blindspot_mv_refresh') THEN RETURN; END IF;
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_tevo_blindspot_movers;
  END $body$; $cron$);

-- ---------------------------------------------------------------------------
-- 3b. s4kcs_map_events_10min — CRM order mapping, 170s limit
--
-- This is on the N2S path (it maps the CRM marketplace orders the sub finder
-- covers), so it gets headroom rather than throttling: 170s -> 240s, and the
-- shadow leg drops to a 5-minute-cadence gate so a slow parity dry-run cannot
-- eat the mapping budget.
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('s4kcs_map_events_10min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 's4kcs_map_events_10min');

SELECT cron.schedule(
  's4kcs_map_events_10min',
  '6-59/10 * * * *',
  $cron$
  BEGIN; SET LOCAL statement_timeout='240s'; SELECT public.event_mapper_run('s4kcs_orders'); COMMIT;
  BEGIN; SET LOCAL statement_timeout='120s';
    SELECT public.event_mapper_shadow_tick('s4kcs_orders')
     WHERE EXTRACT(minute FROM clock_timestamp())::int % 30 = 6;
  COMMIT;
  $cron$);

-- ---------------------------------------------------------------------------
-- 3c. sg_classify_events_5min — tier gate for the SG sales path
--
-- 60.4s mean against a 5-minute limit, so the timeout only bites on the tail.
-- Raised to 8 minutes and moved off :03 (which collides with the 3-59/5 band).
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('sg_classify_events_5min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sg_classify_events_5min');

SELECT cron.schedule(
  'sg_classify_events_5min',
  '1-59/5 * * * *',
  $cron$ SET statement_timeout='8min';
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_classify_events_5min') THEN RETURN; END IF;
    PERFORM public.sg_classify_events();
  END $body$; $cron$);

-- ---------------------------------------------------------------------------
-- 4. De-collide the remaining every-minute jobs
--
-- After the TD/wiki/health removals the survivors on '* * * * *' are:
--   n2s_pipeline_tick_1min          (keeps the minute — priority)
--   gt_ingest_drain_1min            (drain; must stay 1-min to keep up)
--   espn-live-score-poll            (already self-gates on a live-game check)
--   sg_listings_process_on_demand_2min
--
-- Only sg_listings_process_on_demand needs moving: it is named _2min but runs
-- '* * * * *'. Onto odd minutes, so the n2s tick shares its mark with the GT
-- drain alone rather than a crowd of four.
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('sg_listings_process_on_demand_2min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sg_listings_process_on_demand_2min');

SELECT cron.schedule(
  'sg_listings_process_on_demand_2min',
  '1-59/2 * * * *',
  $cron$ SET statement_timeout='100s'; SELECT public.sg_broker_listings_process(50); $cron$);

-- espn-live-score-poll is deliberately NOT touched. Its body already opens with
-- `IF NOT public.espn_has_live_tracked_game() THEN RETURN; END IF;` — a cheap
-- self-gate that returns immediately whenever no tracked game is live. That is
-- strictly better than a cron_policy interval (it responds to whether there is
-- actually work, not to the clock), so an earlier draft of this migration that
-- replaced it with a peak/offpeak policy was a downgrade and is dropped.
