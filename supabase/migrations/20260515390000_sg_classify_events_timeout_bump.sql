-- Migration 20260515390000 · admin · band-aid: bump statement_timeout on sg_classify_events_5min · pre:20260515380000
-- After today's drain-cron cascade, sg_classify_events surfaced as an independent timeout: its
-- 7-day listings_snapshots aggregation hits the default 2-min statement_timeout.
--
-- This is a BAND-AID. Proper fix is to refactor sg_classify_events() to use latest_event_metrics
-- matview (pre-aggregated) or narrow the 7-day window. Deferred to next session — for now,
-- bumping the cron wrapper's timeout to 5 min mirrors midnight-catchup-sweep's pattern.
--
-- Risk: cron fires every 5 min; if function genuinely takes 5+ min, fires will queue. pg_cron
-- serializes by jobid so no concurrent execution, but cron_gate_decisions may show skip_interval
-- if a fire lands while predecessor still running. Acceptable for band-aid.

SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname='sg_classify_events_5min'),
  command := $cmd$DO $body$ BEGIN IF NOT public.cron_should_fire('sg_classify_events_5min') THEN RETURN; END IF; SET LOCAL statement_timeout = '5min'; PERFORM public.sg_classify_events(); END $body$;$cmd$
);
