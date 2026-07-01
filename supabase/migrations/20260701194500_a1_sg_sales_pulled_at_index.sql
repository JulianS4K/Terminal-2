-- ============================================================================
-- Migration 20260701194500 — seatgeek_sales_snapshots(pulled_at) index
--
-- Lane:     A1
-- Touches:  new index public.idx_sg_sales_pulled_at ON seatgeek_sales_snapshots(pulled_at).
-- Pre-reqs: none.
--
-- WHY (cron-health cleanup, operator 2026-07-01 "continue rest"):
--   seatgeek_sales_snapshots (13.2M rows / 5.7 GB) had pulled_at ONLY as a non-leading
--   column in composite indexes (dedup (sg_event_id,sg_sale_id,pulled_at)), so any
--   `WHERE pulled_at > now()-interval` probe seq-scanned the whole table and hit
--   statement_timeout. That broke:
--     - sg_broker_sales_metrics_refresh_hourly (62% fail) — its cron_should_fire work_check
--       `EXISTS(... WHERE pulled_at > now()-'65 minutes')` timed out (the refresh BODY was
--       already fixed per-event in mig 20260701151952, but the GATE probe still scanned).
--     - sg_lifetime_sales_daily (100% fail) — sg_sales aggregate.
--   With this index the gate probe drops to an Index Only Scan (~0.05 ms, verified via EXPLAIN).
--
-- Applied to prod LIVE (non-CONCURRENTLY build survived the 60s MCP tool timeout server-side;
-- observed 0 blocked backends + scheduler stayed fresh throughout). This file is the durable
-- record; IF NOT EXISTS makes re-apply a no-op. On a fresh env this locks the table briefly —
-- acceptable there (empty/small). For future hot-table index builds prefer CREATE INDEX
-- CONCURRENTLY run off-MCP (MCP wraps statements in a txn, which CONCURRENTLY rejects).
--
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_sg_sales_pulled_at
  ON public.seatgeek_sales_snapshots (pulled_at);
