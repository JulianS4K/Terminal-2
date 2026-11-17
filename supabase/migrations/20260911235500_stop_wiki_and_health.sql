-- ============================================================================
-- Migration 20260911235500 — stop the wiki enrichment crons and the health monitor
-- Migration 20260911235500 · level:data-collection · lane:A1 · writes:cron.job,cron_policy · reads:none · pre:20260911234000
--
-- Lane:     A1 (crons)
-- Touches:  cron.job (W), cron_policy (W)
-- Pre-reqs: 20260911234000 (which throttled these; this supersedes that for wiki)
--
-- Operator directive 2026-09-11: stop reading wiki, stop health.
--
-- WIKI — 8 jobs, and the worst cache behaviour in the database. Over the
-- 38-day pg_stat_statements window pww_wiki_process() alone is:
--   7.58 BILLION shared_blks_read  (the largest of any statement)
--   25.5% cache hit ratio          (the worst of any statement)
--   304 hours total, mean 38.5s, on a '* * * * *' schedule
-- At a 25% hit ratio it reads three blocks from disk for every one it finds in
-- a 2 GB cache, and every one of those evicts something another job needed.
-- 20260911234000 throttled it to 20-min at peak; this stops it outright, which
-- supersedes that row.
--
-- HEALTH — health_monitor_5min is the #2 consumer of total time in the whole
-- database: 320 hours over 9,696 calls, mean 118.8 SECONDS, on a 5-minute
-- schedule. It spends ~40% of its own interval running, and 5.04B block reads
-- at 82.9% hit doing it.
--
-- ⚠ WHAT GOES DARK WITH health_monitor_5min — this is a real loss, recorded
-- here so it is a decision and not an accident. Per RESOURCES_BIBLE §5 that one
-- job also carries two piggybacked monitors:
--   * record_source_freshness()  — the per-source SLA rows (evo_listings 10/30m,
--     sg 90m/6h, td 8h/26h, ...). This is what caught "SG dark for 2.5 days"
--     and what currently reports td_listings as failed.
--   * record_cron_deadman()      — hours-since-last-success vs SLA for the
--     daily/12h jobs (snapshots, movers_agg, gap refresh, sg_lifetime,
--     listings_deltas, rosters-daily). Catches a scheduled job silently never
--     firing, which produces no failure row to notice.
-- With this applied, a source going stale or a daily job wedging is no longer
-- detected automatically. The D0 health page (static/terminal/health.html)
-- still renders live cron.job + job_run_details state, so per-job run health
-- remains visible on demand — it is the SLA alerting that stops.
--
-- If partial coverage is wanted back later, the cheap option is this job on a
-- 30-minute schedule rather than 5 (mean 118.8s over 1800s = ~7% duty cycle
-- instead of ~40%); it needs only a cron.schedule call, no code change.
--
-- NOT touched: mapping_health_check_daily — different thing entirely (the
-- data-poll/event-mapping drift sweep behind the check-poll-mapping-health
-- skill, CLAUDE.md §5). Daily, cheap, read-only.
-- ============================================================================

DO $do$
DECLARE
  v_job text;
BEGIN
  FOREACH v_job IN ARRAY ARRAY[
    -- performer/venue wiki (pww_*) — the 7.58B-block reader
    'pww_wiki_process_1min',
    'pww_wiki_queue_1min',
    -- athlete wiki: searches, summaries, pageviews, sweep
    'athlete_wiki_queue_searches',
    'athlete_wiki_process_searches',
    'athlete_wiki_process_summaries',
    'athlete_wiki_pageviews_queue',
    'athlete_wiki_pageviews_process',
    'athlete_wiki_pending_sweep',
    -- the health monitor itself
    'health_monitor_5min'
  ] LOOP
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_job) THEN
      PERFORM cron.unschedule(v_job);
    END IF;
  END LOOP;
END
$do$;

-- Mark the policy rows disabled so the gate ledger agrees with reality and the
-- 20260911234000 throttle rows do not read as live config.
UPDATE public.cron_policy
   SET enabled = false,
       notes = coalesce(notes,'') ||
               ' [STOPPED 20260911235500 — operator: stop reading wiki, stop health.]',
       updated_at = now()
 WHERE jobname IN (
   'pww_wiki_process_1min','pww_wiki_queue_1min',
   'athlete_wiki_queue_searches','athlete_wiki_process_searches',
   'athlete_wiki_process_summaries','athlete_wiki_pageviews_queue',
   'athlete_wiki_pageviews_process','athlete_wiki_pending_sweep',
   'health_monitor_5min');
