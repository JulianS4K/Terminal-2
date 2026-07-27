-- Migration 20260516010000 · admin · cron cluster fixes (HOT 240s, re-resume 5 trailing-semi, 5 timeout band-aids) · pre:20260516000000
-- Operator directive 2026-05-16. Three classes of cron fixes:
--
-- 1. HOT tier polling: 60s → 240s. With sg_priority_poll_tick split budget (PR #138), HOT
--    coverage was at 2 min/event (25 polls/min, ~50 HOT events). At 240s, each event gets
--    polled every 4 min, reducing total HOT traffic by 4×. Tradeoff: signal latency on HOT
--    events goes 60s → 240s. Acceptable per operator decision.
--
-- 2. Five trailing-semicolon-broken crons (collect-listings-{1-7d,7-30d,30-60d,60d+} +
--    espn-team-daily): re-resume via cron_resume_with_gate, which has the regex_replace
--    fix from PR #112. The crons were re-enabled previously but never re-resumed via the
--    fixed helper, so they kept the old `; END $body$;` syntax error.
--
-- 3. Five timeout-class crons get SET LOCAL statement_timeout='5min' wrappers:
--      - dashboard_writes_24h_refresh_60s (matview refresh)
--      - compute_alerts_tick_15min
--      - match_listings_to_sg_30min
--      - sweep_terminal_event_listings_hourly
--      - orphan_event_backfill_queue_15min (new inner timeout post-FK-drop)
--    Same pattern as midnight-catchup-sweep (already had this) + sg_classify (PR #135).
--    Band-aid: function-level optimization deferred for sg_classify, listings_deltas, midnight-catchup.

-- 1. HOT tier 60s → 240s
UPDATE public.sg_priority_policy SET interval_seconds = 240 WHERE tier = 'HOT';

-- 2. Re-resume the 5 trailing-semicolon-broken crons
SELECT public.cron_resume_with_gate('collect-listings-1-7d');
SELECT public.cron_resume_with_gate('collect-listings-7-30d');
SELECT public.cron_resume_with_gate('collect-listings-30-60d');
SELECT public.cron_resume_with_gate('collect-listings-60d+');
SELECT public.cron_resume_with_gate('espn-team-daily');

-- 3. statement_timeout band-aids on 5 timeout-class crons
SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname='dashboard_writes_24h_refresh_60s'),
  command := $cmd$DO $body$ BEGIN IF NOT public.cron_should_fire('dashboard_writes_24h_refresh_60s') THEN RETURN; END IF; SET LOCAL statement_timeout = '5min'; REFRESH MATERIALIZED VIEW CONCURRENTLY v_dashboard_writes_24h; END $body$;$cmd$
);

SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname='compute_alerts_tick_15min'),
  command := $cmd$DO $body$ BEGIN IF NOT public.cron_should_fire('compute_alerts_tick_15min') THEN RETURN; END IF; SET LOCAL statement_timeout = '5min'; PERFORM compute_alerts_tick(); END $body$;$cmd$
);

SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname='match_listings_to_sg_30min'),
  command := $cmd$DO $body$ BEGIN IF NOT public.cron_should_fire('match_listings_to_sg_30min') THEN RETURN; END IF; SET LOCAL statement_timeout = '5min'; PERFORM public.match_listings_to_sg_tick(); END $body$;$cmd$
);

SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname='sweep_terminal_event_listings_hourly'),
  command := $cmd$DO $body$ BEGIN IF NOT public.cron_should_fire('sweep_terminal_event_listings_hourly') THEN RETURN; END IF; SET LOCAL statement_timeout = '5min'; PERFORM public.sweep_terminal_event_listings(50); END $body$;$cmd$
);

SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname='orphan_event_backfill_queue_15min'),
  command := $cmd$DO $body$ BEGIN IF NOT public.cron_should_fire('orphan_event_backfill_queue_15min') THEN RETURN; END IF; SET LOCAL statement_timeout = '5min'; PERFORM evo_event_backfill_queue(20), sg_event_backfill_queue(20); END $body$;$cmd$
);
