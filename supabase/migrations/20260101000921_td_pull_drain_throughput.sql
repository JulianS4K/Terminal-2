-- Migration 20260609170000 · lane:D0 (author) → A1 (apply) ·
--   writes: reschedules the existing td_pull_drain pg_cron job ·
--   pre: 20260609150000 (tier crons)
--
-- ## APPLIED to prod 2026-06-09 (operator-authorized activation).
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- td_pull_drain fired only p_max=1 request/minute (~1,440/day) — fine for the old
-- ~300/day flat regime, but the tiered owned-book design targets ~5k/day. Raise
-- to 5/minute (~7,200/day capacity). Actual spend stays bounded by td_budget_ok
-- (6,000/day recorded) at the ENQUEUE side, so 5/min just lets the queue drain at
-- the budgeted rate instead of bottlenecking. TicketsData concurrency guidance is
-- 5–15 simultaneous; 5/min keeps in-flight count low. Reversible: set back to (1).
-- ─────────────────────────────────────────────────────────────────────────────
SELECT cron.schedule('td_pull_drain', '* * * * *',
  $$DO $body$ BEGIN PERFORM public.td_pull_drain(5); END $body$;$$);
