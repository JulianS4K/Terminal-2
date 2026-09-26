-- Migration 20260926144628 · level:secondary-sales · lane:D7 · writes:cron.job · reads:none · pre:20260926013358
--
-- Already applied to prod · via MCP 2026-09-26 under operator direction, after a
-- rolled-back dry run (both schedules accepted; prod confirmed unchanged).
--
-- ============================================================================
-- Migration 20260926144628 — take N2S load off the pg_cron scheduler
--
-- Lane: D7 · Pre-reqs: 20260926013358 (direct fetch at 40 s)
--
-- The project logs ~1,980 "job startup timeout" cron failures a day across
-- 207 active jobs (24 h to 2026-09-26 14:30 UTC). The single scheduler
-- process stalls and then handles a backlog at once (dozens of unrelated jobs
-- log completion in the same millisecond; "20 seconds" jobs actually fire every
-- 35–80 s), and anything left waiting past the startup limit is failed. Two
-- D7 jobs made it worse:
--
--   n2s_crm_direct_20s — 5th-largest scheduler consumer: 590 run-minutes/day,
--     128 startup timeouts and 100 statement timeouts in 24 h, for a typical
--     ~30 s head start over pg_net on ~3/4 of new orders. Now every minute
--     ('* * * * *'): keeps most of the head start at ~1/3 of the scheduler
--     time. ('N seconds' interval schedules only go to 59, so a minute is a
--     standard cron line.) pg_cron cannot rename a job in place, so the name
--     keeps its '_20s' suffix; the schedule is the truth.
--
--   n2s_book_snapshot_hourly — at :37 it failed 13 of 24 runs (:37 is the
--     worst minute of the hour, 42% of cron starts there time out), so the
--     hourly exposure series behind the N2S P&L was missing more than half its
--     points. Moved to :33 (2.5% startup failures over the same 24 h).
--
-- Root cause of the scheduler stall is NOT fixed here — it is project-wide and
-- mostly A1's jobs; raised separately in bot_chat.
-- ============================================================================

SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_crm_direct_20s'),
                      schedule := '* * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_book_snapshot_hourly'),
                      schedule := '33 * * * *');

-- rollback:
-- SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_crm_direct_20s'), schedule := '20 seconds');
-- SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'n2s_book_snapshot_hourly'), schedule := '37 * * * *');
