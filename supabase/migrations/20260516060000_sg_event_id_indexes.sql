-- Migration 20260516060000 · admin · SG sg_event_id indexes for v2 RPC · pre:20260516050000
--
-- Index gap discovered while validating get_broker_event_page_v2 (20260516050000):
-- SG snapshot tables have unindexed sg_event_id (their actual FK from the SG API side).
-- The pre-existing (tevo_event_id, time_col) indexes are partial WHERE tevo_event_id
-- IS NOT NULL, but tevo_event_id is **0% populated** on these tables (ingest writes
-- sg_event_id only; the bridge backfill never ran).
--
-- Effect without these indexes: every v2 RPC call seq-scans 1-10M-row tables for
-- SG payload keys (sales_tape, sg_side_by_side, freshness). Function consistently
-- times out at 2 min on first call.
--
-- After indexes: v2 RPC completes in ~185ms typical (verified on Bruno Mars event
-- 3262932 with richest payload — sales tape + 6-point forecast + ESPN standings +
-- splits + freshness).
--
-- Note: not addressing the underlying tevo_event_id backfill gap here — that's a
-- separate ingest workstream. These indexes match the actual data shape today.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16.

CREATE INDEX IF NOT EXISTS idx_sg_sales_sg_event_id_time
  ON public.seatgeek_sales_snapshots (sg_event_id, sale_at_utc DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_sg_listings_sg_event_id_time
  ON public.seatgeek_listings_snapshots (sg_event_id, captured_at DESC);

CREATE INDEX IF NOT EXISTS idx_sg_event_metrics_sg_event_id_time
  ON public.seatgeek_event_metrics (sg_event_id, captured_at DESC);
