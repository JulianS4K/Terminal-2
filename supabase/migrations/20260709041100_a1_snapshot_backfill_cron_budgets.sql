-- ============================================================================
-- Migration 20260709041100 — event_snapshot_* cron budget 480s → 2700s;
--   listings_deltas_backfill_overnight gets its own prefix + chunk 30 → 10
--
-- Lane:     A1
-- Touches:  cron.job command only (event_snapshot_morning / event_snapshot_midday /
--           event_snapshot_evening / listings_deltas_backfill_overnight).
-- Pre-reqs: 20260708042000 (gate-clamp fix — an in-string prefix survives the
--           cron_should_fire call), 20260708164500 (movers 2700s precedent).
--
-- WHY (2026-07-09 poll-mapping-health sweep, bot_chat 3296):
--   * event_snapshot_{morning,midday,evening} failed 3 consecutive slots
--     (07-08 13:30 / 19:30 / 07-09 03:30 UTC), each canceled at exactly its
--     in-string 8min budget inside compute_event_listing_snapshot() —
--     event_listing_snapshot_daily is stale since the 07-08 03:30 evening
--     slot (it feeds get_sg_market_chart()'s sh_* columns while the SG
--     listings path stays dark). Growth driver same as movers: TD snapshot
--     volume from the SG surplus burn. 2700s mirrors the approved movers
--     stopgap; each job runs once daily ≥6h apart, so no overlap. Volume
--     drops when td_sg_burn_teardown fires (7/9) + A1-OPS-29 retention lands.
--   * listings_deltas_backfill_overnight (sole listings_snapshots.prev_*
--     populater) failed 11/15 burst runs at 900s — a budget it never set:
--     its command carries NO prefix, and the fn's internal SET LOCAL '5min'
--     is a no-op on its own running statement (PROJECT_BIBLE §3), so each
--     run inherited whatever leaked onto the pooled cron connection. Give it
--     an explicit 840s prefix and shrink the chunk 30 → 10: the fn drains
--     smallest-events-first, so the remaining backlog is the expensive tail
--     (~30s+/event observed) — 10 events fits 840s with headroom instead of
--     burning 15min to roll back 30.
-- Already applied to prod · via MCP 2026-07-09 (operator-approved this session).
-- Idempotent: cron.alter_job to fixed command text; re-apply is a no-op.
--   The backfill alter is guarded — that job self-unschedules when the
--   backlog drains, and a missing job means there is nothing left to fix.
-- ============================================================================

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'event_snapshot_morning'),
  command := $cmd$SET statement_timeout='2700s'; SELECT public.compute_event_listing_snapshot('morning') WHERE public.cron_should_fire('event_snapshot_morning');$cmd$);

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'event_snapshot_midday'),
  command := $cmd$SET statement_timeout='2700s'; SELECT public.compute_event_listing_snapshot('midday') WHERE public.cron_should_fire('event_snapshot_midday');$cmd$);

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'event_snapshot_evening'),
  command := $cmd$SET statement_timeout='2700s'; SELECT public.compute_event_listing_snapshot('evening') WHERE public.cron_should_fire('event_snapshot_evening');$cmd$);

DO $mig$
DECLARE v_id bigint;
BEGIN
  SELECT jobid INTO v_id FROM cron.job WHERE jobname = 'listings_deltas_backfill_overnight';
  IF v_id IS NOT NULL THEN
    PERFORM cron.alter_job(v_id, command := $cmd$SET statement_timeout='840s';
DO $cronbody$
DECLARE v_remaining int;
BEGIN
  IF NOT public.cron_should_fire('listings_deltas_backfill_overnight') THEN RETURN; END IF;
  SELECT max(events_remaining) INTO v_remaining
  FROM public.listings_deltas_backfill_chunked(10);
  IF coalesce(v_remaining, 0) = 0 THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'listings_deltas_backfill_overnight'));
  END IF;
END $cronbody$;$cmd$);
  END IF;
END $mig$;
