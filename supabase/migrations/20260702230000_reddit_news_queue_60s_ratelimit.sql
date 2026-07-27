-- ============================================================================
-- Migration 20260702230000 — Reddit news queue: 30s → 60s (old.reddit rate limit)
--
-- Lane:     D0 (author) → A1 (apply)   [D0 has no prod-DB apply authority]
-- Touches:  cron.job (reschedule), reddit_news_flairs (reset last_polled_at)
-- Pre-reqs: 20260626120030 (reddit_news_queue + reddit_news_queue_30s cron)
--
-- WHY: the '30 seconds' queue cadence (mig 20260626120030) exceeds old.reddit's
--   rate limit. Verified live 2026-07-02 21:xx — requests 60s apart all return
--   200, but every request 30s after a prior one returns 429. At 30s cadence
--   exactly every OTHER poll was rejected, so ~half the enabled subs (nba,
--   Broadway, Music, hockey, wnba, CollegeBasketball, NFLDraft) persisted 0 rows.
--   old.reddit tolerates ~1 request / 60s from our pg_net IP.
--
-- FIX: reschedule the queue to fire ONE sub per minute (all polls succeed). ~14
--   enabled subs → each polled ~every 14 min. That is the fastest sustainable
--   cadence for this sub count; the retention (48h) + round-robin keep the ticker
--   full and continuously fed (a fresh sub lands every minute). The 4-min floor
--   in reddit_news_queue() still binds only when few subs are enabled.
--
--   NOTE: pg_cron's sub-minute format only accepts '[1-59] seconds', so a 60s
--   cadence must use the standard cron expression '* * * * *' (every minute =
--   exactly 60s spacing), NOT '60 seconds' (rejected: "invalid schedule").
--
--   Also NULLs last_polled_at on the enabled subs so the round-robin restarts
--   cleanly and the previously-429'd (0-row) subs are picked up first.
-- ============================================================================

-- Reschedule: drop the 30s job, add the 1-min job (rename makes the cadence obvious).
SELECT cron.unschedule('reddit_news_queue_30s')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_news_queue_30s');
SELECT cron.unschedule('reddit_news_queue_1min')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_news_queue_1min');

SELECT cron.schedule(
  'reddit_news_queue_1min',
  '* * * * *',
  $$ SELECT reddit_news_queue(1); $$
);

-- Restart the round-robin so the subs that only ever hit a 429 slot backfill now.
UPDATE reddit_news_flairs SET last_polled_at = NULL WHERE enabled;
