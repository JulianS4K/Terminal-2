-- Migration 20261021172000 · level:admin · lane:A1 · writes:cron.job (10 commands, 12 schedules, 1 active flag) · reads:cron.job_run_details · pre:20260926170000, 20260911240000
--
-- ============================================================================
-- Migration 20261021172000 — cron phase 1: single-statement commands for the 10
--   worst scheduler blockers, re-stagger the :13/:43/:17 pile-ups, make the
--   venue-section rollup daily, retire the dead AXS backfill
--
-- Already applied to prod · via MCP 2026-10-21 17:18 UTC under operator
--   direction ("Yes — apply all of it"). Verified post-apply: all 16 touched
--   jobs carry the new command/schedule/active state; active multi-statement
--   commands 33 → 23. Baseline for the 30 min before (16:47–17:17 UTC):
--   704 runs, 1 startup timeout, 2 failed. RESULT (measured 20:17 UTC): the
--   five hours before (12:00–16:59) ran 14–35 startup timeouts/hour; from
--   18:00 to 20:17 (~2,700 runs) ZERO startup timeouts and zero failures. All
--   14 touched jobs ran clean (663 p50 8.8 s, 642 10 s, 637 64 s, 536 128 s,
--   635 498 s). The 16 Exos jobs were also paused at ~17:45 (20261021174000),
--   so the gain is shared between the two changes.
--
-- Lane:     A1 (data plane / crons) · 2026-10-21 audit rows KANBAN A1-DB-4, A1-DB-5
-- Touches:  cron.job rows (W via cron.alter_job) for jobs 153, 226, 263, 428,
--           473, 479, 536, 536, 635, 637, 642, 659, 663 — commands, schedules,
--           one active flag. No function bodies, no table rows.
-- Pre-reqs: 20260926170000 (the n2s tick single-statement experiment this
--           extends), 20260911240000 (current 479 command shape).
--           Every function referenced below already exists.
--
-- WHY (single statement): with `cron.use_background_workers=off` the single
--   pg_cron launcher dispatches jobs over libpq and, as 20260926170000 showed
--   on job 640, a MULTI-statement command (`SET …; SELECT …;` /
--   `BEGIN; SET LOCAL …; DO …; COMMIT;`) stalls the launcher for the whole run:
--   nothing else starts or is recorded until it ends, and the backlog fails as
--   "job startup timeout". That fix cut "starts within 1 s of a tick end" from
--   88.7% → 16.1% and was kept. 33 active jobs still carry the pattern and in
--   the 24 h to 2026-10-21 17:00 UTC: 34,141 starts, 40.4% within 1 s of a
--   multi-statement job's end, 682 startup timeouts (2% of all runs), clustered
--   at :13/:43 (663 + 642 end), :17 (536 + 226), :x6 (637). None of the nine
--   converted here hit its statement_timeout cap in 7 days (p95 well under:
--   663 22 s/60 s, 642 23 s/170 s, 637 90 s/240 s, 153 43 s/300 s, 226 143 s/
--   300 s, 263 21 s/300 s, 536 144 s/170 s, 659 90 s/170 s, 635 bounded by its
--   own 120/480 s budget), so dropping the wrapper removes a cap they never
--   used; the role default statement_timeout (900 s) remains the backstop, and
--   per-statement budgets belong inside the functions (clock_timestamp), not in
--   a SET that a DO block ignores (PROJECT_BIBLE §3).
--   Two-transaction jobs (536, 637) keep their "second step may fail
--   independently" semantics with a nested BEGIN … EXCEPTION block, the shape
--   20260926212000 used for 629.
--
-- WHY (479 daily): venue_section_rollup_hourly has failed 168/168 runs in 7 d
--   (statement timeout at 600 s inside refresh_venue_section_aggs — a full
--   DELETE + DISTINCT ON rebuild over 7.56 M venue_section_price_daily rows with
--   no matching index), holding a worker 10 min of every hour. The source
--   (section_metrics) has produced ~1 row/day since the 2026-09-27 poller
--   pause, so hourly is 24× the work the data warrants. Daily at 04:52 UTC
--   (off-peak) under the 900 s default gives the refresh a real chance to
--   finish and caps the waste at 15 min/day. The proper fix (incremental agg
--   refresh + partial index on (event_id, section_key, snapshot_date DESC))
--   stays open as KANBAN A1-DB-4.
--
-- WHY (re-stagger): startup timeouts in 7 d by minute: :13 158, :43 159,
--   :17 114, :26 67. Moving the long jobs off the shared minutes spreads the
--   remaining multi-statement load until phase 2 converts the other 24.
--   637 moves :6 → :7 of each 10 min, so its "shadow tick twice an hour"
--   minute test moves with it (6 → 7).
--
-- WHY (428 off): axs-sg-url-anchor-backfill returns UPDATE 0 every day; AXS
--   collection is paused (KANBAN A1-OPS-25). Deactivated, not unscheduled.
--
-- Rollback: the ORIGINAL command / schedule of every row is quoted at the
--   bottom of this file; `cron.alter_job(jobid, command := …, schedule := …)`
--   restores each one.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A. Single-statement commands
-- ---------------------------------------------------------------------------

-- 153 dashboard_writes_24h_refresh_60s  (was: SET 5min; DO …)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'dashboard_writes_24h_refresh_60s'),
  command := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('dashboard_writes_24h_refresh_60s') THEN RETURN; END IF;
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.v_dashboard_writes_24h;
END $b$;$c$);

-- 226 sg_broker_sales_metrics_refresh_hourly  (was: SET 5min; SELECT … WHERE cron_should_fire)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'sg_broker_sales_metrics_refresh_hourly'),
  command := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('sg_broker_sales_metrics_refresh_hourly') THEN RETURN; END IF;
  PERFORM public.refresh_sg_broker_sales_event_metrics(200);
END $b$;$c$);

-- 263 sg_blindspot_mv_refresh  (was: SET 5min; DO …)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'sg_blindspot_mv_refresh'),
  command := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('sg_blindspot_mv_refresh') THEN RETURN; END IF;
  REFRESH MATERIALIZED VIEW public.mv_sg_blindspot_movers;
END $b$;$c$);

-- 479 venue_section_rollup_hourly  (was: BEGIN; SET LOCAL 600s; DO …; COMMIT;)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'venue_section_rollup_hourly'),
  command := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('venue_section_rollup_hourly') THEN RETURN; END IF;
  PERFORM public.venue_section_rollup_catchup(2, 200);
END $b$;$c$);

-- 536 gt_map_events_hourly  (was: two BEGIN/SET LOCAL/SELECT/COMMIT transactions)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'gt_map_events_hourly'),
  command := $c$DO $b$ BEGIN
  PERFORM public.event_mapper_run('gotickets_event');
  BEGIN
    PERFORM public.event_mapper_shadow_tick('gotickets_event');
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt shadow tick skipped: %', SQLERRM;
  END;
END $b$;$c$);

-- 635 retention_tick_hourly  (was: BEGIN; SET LOCAL 600s; DO …; COMMIT;)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'retention_tick_hourly'),
  command := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('retention_tick_hourly') THEN RETURN; END IF;
  PERFORM public.retention_tick(CASE WHEN public.is_peak() THEN 120 ELSE 480 END);
END $b$;$c$);

-- 637 s4kcs_map_events_10min  (was: two BEGIN/SET LOCAL/SELECT/COMMIT transactions;
--     the shadow tick ran on minutes 6 and 36 — the schedule moves to :7, so
--     the test moves to 7 and 37)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 's4kcs_map_events_10min'),
  command := $c$DO $b$ BEGIN
  PERFORM public.event_mapper_run('s4kcs_orders');
  IF EXTRACT(minute FROM clock_timestamp())::int % 30 = 7 THEN
    BEGIN
      PERFORM public.event_mapper_shadow_tick('s4kcs_orders');
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 's4kcs shadow tick skipped: %', SQLERRM;
    END;
  END IF;
END $b$;$c$);

-- 642 marketplace_orders_map_30min  (was: BEGIN; SET LOCAL 170s; DO …; COMMIT;)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'marketplace_orders_map_30min'),
  command := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('marketplace_orders_map_30min') THEN RETURN; END IF;
  PERFORM public.event_mapper_run('vivid_orders');
  PERFORM public.event_mapper_run('tickpick_orders');
END $b$;$c$);

-- 659 id_spine_tick_15min  (was: BEGIN; SET LOCAL 170s; DO …; COMMIT; — body unchanged)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'id_spine_tick_15min'),
  command := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('id_spine_tick_15min') THEN RETURN; END IF;
  PERFORM public.event_mapper_anchor_ids();
  PERFORM public.tickets_dev_run(150);
  PERFORM public.tickets_dev_fill_outward(150);
  PERFORM public.tickets_dev_search_harvest();
  PERFORM public.sg_canonical_seed_from_orders(true);   -- mig 20260928190000
  PERFORM public.seatgeek_orders_recover_event_id(true);
  PERFORM public.event_mapper_gt_fallback('s4kcs_orders', true);
  PERFORM public.event_mapper_gt_fallback('vivid_orders', true);
  PERFORM public.event_mapper_gt_fallback('tickpick_orders', true);
  PERFORM public.event_mapper_gt_fallback('sg_events_canonical', true);
  PERFORM public.tickets_dev_search_enqueue('s4kcs_orders', 60);
  PERFORM public.tickets_dev_search_enqueue('sg_events_canonical', 60);
  PERFORM public.venue_xref_derive_by_id(true);
  PERFORM public.performer_xref_derive_from_events(true);
  -- mig 20260917000000: the linkers, last, in precedence order (see header)
  PERFORM public.s4kcs_link_gotickets(true);
  PERFORM public.s4kcs_link_marketplaces(true);
  PERFORM public.s4kcs_link_tickets_dev(true);
  PERFORM public.n2s_link_gotickets(true);
END $b$;$c$);

-- 663 n2s_gt_map_by_name_full_30min  (was: SET 60s; DO …)
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'n2s_gt_map_by_name_full_30min'),
  command := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('n2s_gt_map_by_name_full_30min') THEN RETURN; END IF;
  PERFORM * FROM public.n2s_gt_map_by_name();
END $b$;$c$);

-- ---------------------------------------------------------------------------
-- B. Schedules — off the :13/:43/:17/:53 pile-ups; 479 → daily off-peak
-- ---------------------------------------------------------------------------
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'venue_section_rollup_hourly'),      schedule := '52 4 * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_gt_map_by_name_full_30min'),    schedule := '14,44 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'marketplace_orders_map_30min'),     schedule := '16,46 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'aq_reschedule_sync_from_tevo_30min'), schedule := '19,49 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'sg_blindspot_mv_refresh'),          schedule := '5-59/10 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'gt_map_events_hourly'),             schedule := '32 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'sg_broker_sales_metrics_refresh_hourly'), schedule := '47 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 's4kcs_map_events_10min'),           schedule := '7-59/10 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'sg_fill_rate_hourly'),              schedule := '57 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'ppm_queue_2x_hourly'),              schedule := '21,51 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'venue_geocode_queue_5min'),         schedule := '25,55 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'venue_geocode_process_5min'),       schedule := '25,55 * * * *');

-- ---------------------------------------------------------------------------
-- C. Dead job off (not unscheduled)
-- ---------------------------------------------------------------------------
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'axs-sg-url-anchor-backfill'), active := false);

-- ---------------------------------------------------------------------------
-- Post-apply checks
--   SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobid IN
--     (153,226,263,428,473,479,536,635,637,642,659,663);           -- new schedules; 428 inactive
--   SELECT count(*) FROM cron.job WHERE active AND (command ~* 'BEGIN;' OR
--     command ~* '^\s*SET\s' OR command ~* ';\s*SET\s');              -- 33 → 24
--   After 30 min, vs the 30 min before:
--   SELECT count(*) FILTER (WHERE return_message='job startup timeout')
--   FROM cron.job_run_details WHERE start_time > now()-interval '30 min';
--   SELECT date_trunc('minute', start_time), count(*) FROM cron.job_run_details
--   WHERE start_time > now()-interval '30 min' AND return_message='job startup timeout'
--   GROUP BY 1 ORDER BY 1;                                              -- :13/:43/:17 spikes gone
--
-- ROLLBACK (original rows, verbatim from cron.job on 2026-10-21):
--   153 '8 * * * *'       SET statement_timeout='5min'; DO $body$ BEGIN IF NOT public.cron_should_fire('dashboard_writes_24h_refresh_60s') THEN RETURN; END IF;  REFRESH MATERIALIZED VIEW CONCURRENTLY v_dashboard_writes_24h; END $body$;
--   226 '17 * * * *'      SET statement_timeout='5min'; SELECT public.refresh_sg_broker_sales_event_metrics(200) WHERE public.cron_should_fire('sg_broker_sales_metrics_refresh_hourly');
--   263 '3-59/10 * * * *' SET statement_timeout = '5min'; DO $body$ BEGIN IF NOT public.cron_should_fire('sg_blindspot_mv_refresh') THEN RETURN; END IF; REFRESH MATERIALIZED VIEW public.mv_sg_blindspot_movers; END $body$;
--   428 '11 5 * * *'      active=true (command unchanged)
--   473 '13,43 * * * *'   (command unchanged)
--   479 '52 * * * *'      BEGIN; SET LOCAL statement_timeout='600s'; DO $b$ BEGIN IF NOT public.cron_should_fire('venue_section_rollup_hourly') THEN RETURN; END IF; PERFORM public.venue_section_rollup_catchup(2, 200); END $b$; COMMIT;
--   536 '17 * * * *'      BEGIN; SET LOCAL statement_timeout='170s'; SELECT public.event_mapper_run('gotickets_event'); COMMIT; BEGIN; SET LOCAL statement_timeout='120s'; SELECT public.event_mapper_shadow_tick('gotickets_event'); COMMIT;
--   635 '44 * * * *'      BEGIN; SET LOCAL statement_timeout='600s'; DO $b$ BEGIN IF NOT public.cron_should_fire('retention_tick_hourly') THEN RETURN; END IF; PERFORM public.retention_tick(CASE WHEN public.is_peak() THEN 120 ELSE 480 END); END $b$; COMMIT;
--   637 '6-59/10 * * * *' BEGIN; SET LOCAL statement_timeout='240s'; SELECT public.event_mapper_run('s4kcs_orders'); COMMIT; BEGIN; SET LOCAL statement_timeout='120s'; SELECT public.event_mapper_shadow_tick('s4kcs_orders') WHERE EXTRACT(minute FROM clock_timestamp())::int % 30 = 6; COMMIT;
--   642 '13,43 * * * *'   BEGIN; SET LOCAL statement_timeout='170s'; DO $b$ BEGIN IF NOT public.cron_should_fire('marketplace_orders_map_30min') THEN RETURN; END IF; PERFORM public.event_mapper_run('vivid_orders'); PERFORM public.event_mapper_run('tickpick_orders'); END $b$; COMMIT;
--   659 '8,23,38,53 * * * *' BEGIN; SET LOCAL statement_timeout = '170s'; DO $b$ … (same 18 PERFORMs as above) … END $b$; COMMIT;
--   663 '13,43 * * * *'   SET statement_timeout = '60s'; DO $b$ BEGIN IF NOT public.cron_should_fire('n2s_gt_map_by_name_full_30min') THEN RETURN; END IF; PERFORM * FROM public.n2s_gt_map_by_name(); END $b$;
--   305 '53 * * * *'      (command unchanged)
--   519 '13,43 * * * *'   (command unchanged)
--   202 '23,53 * * * *'   (command unchanged)
--   203 '23,53 * * * *'   (command unchanged)
-- ============================================================================
