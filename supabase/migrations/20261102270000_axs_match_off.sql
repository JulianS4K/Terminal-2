-- Migration 20261102270000 · level:data-collection · lane:A1 (AXS ingest) · writes:cron axs_match_hourly(active=false) · reads:cron.job · pre:20261102260000
--
-- ============================================================================
-- Stop the hourly TicketsData /match job for AXS ids (operator 2026-11-02: "2 do it").
-- Measured: /match returned an axs.com link for 4 of 277 events at AXS venues (1.4 %), at 12 credits
-- + 1 report per call: ~7,200 credits and the whole 600-report monthly cap for ~8 ids. The AXS
-- artist crawl with sitemap artist ids resolved 219 of 260 sampled events for 100 credits instead.
-- Applied on prod by the operator's go-ahead on 2026-11-02 (cron.alter_job, job 695); this file
-- records it. The job and its functions are kept; re-enable with
--   SELECT cron.alter_job(jobid, active := true) FROM cron.job WHERE jobname = 'axs_match_hourly';
-- ============================================================================

SELECT cron.alter_job(j.jobid, active := false)
  FROM cron.job j
 WHERE j.jobname = 'axs_match_hourly' AND j.active;
