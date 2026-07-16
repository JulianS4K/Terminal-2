-- ============================================================================
-- Migration 20260714260000 — Max the LeBron (watch-tier) Wikipedia team ping
--
-- Lane:     A1 data plane
-- Touches:  cron.job (reschedule pww_wiki_queue / pww_wiki_process to 1 min)
-- Pre-reqs: 20260714130000 (pww_wiki pipeline), 20260714230000 (tier)
--
-- WHY: operator — "for LeBron ping the wiki current-team tab for update at max."
--   The Wikipedia REST summary (which carries the "plays for the <team>" hint) was
--   polled on a 5-min cron. Retuned to EVERY MINUTE, with the watch tier due at
--   1 min via pww_wiki_queue's p_min_age arg (track tier stays hourly, enforced
--   in-function). LeBron is the sole watch-tier member, so his current-team is
--   now re-checked ~every minute and a change surfaces within ~a minute. No
--   function change — just cadence.
-- ============================================================================

SELECT cron.unschedule('pww_wiki_queue_5min')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='pww_wiki_queue_5min');
SELECT cron.unschedule('pww_wiki_process_5min') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='pww_wiki_process_5min');

SELECT cron.schedule('pww_wiki_queue_1min',   '* * * * *', $$ SELECT public.pww_wiki_queue(interval '1 minute'); $$);
SELECT cron.schedule('pww_wiki_process_1min', '* * * * *', $$ SELECT public.pww_wiki_process(); $$);
