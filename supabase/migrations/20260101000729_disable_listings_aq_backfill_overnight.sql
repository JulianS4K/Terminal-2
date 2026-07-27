-- Migration 20260601120000 · admin · disable listings_aq_backfill_overnight cron · pre:20260531210000
--
-- Disables (active=false, NOT unscheduled — kept as a tombstone) cron jobid 137
-- `listings_aq_backfill_overnight`. The job was both BROKEN and POINTLESS:
--
-- BROKEN — 13/13 runs failed in the 24h before this migration, every firing
--   dying with "canceling statement due to statement timeout" on the
--   `UPDATE public.listings_snapshots ls SET aq_short_event_id ...` inside
--   `match_unmatched_listings_chunked()` (line 34). Root cause is KANBAN
--   A1-OPS-4: pg_cron enforces a hard ~120s system statement_timeout that
--   OVERRIDES the `SET LOCAL statement_timeout='3min'` in the cron body, so
--   the job dies on the first event's UPDATE. It can never reach
--   events_remaining=0, so the built-in self-unschedule never fires.
--   Compounding it: `listings_snapshots` has grown to ~32.5M rows (authored
--   against 8.16M) and `aq_short_event_id` is 0% populated, so the partial
--   index `... WHERE aq_short_event_id IS NULL` covers EVERY row (no
--   selectivity) and each per-event UPDATE touches tens of thousands of rows
--   plus a per-row FOR KEY SHARE FK lock on aq_event_map.
--
-- POINTLESS — nothing reads `listings_snapshots.aq_short_event_id`. This is
--   the #1 PROJECT_BIBLE §3 landmine: it is the TEvo `SYS-{hex}` system, 0%
--   populated; all readers query `listings_snapshots` by `event_id`. Verified
--   against the live catalog: every function that mentions both the table and
--   the column keys off `aq_event_map` / `ticketsdata_event_xref` via
--   `event_id`/`sg_event_id`, never `ls.aq_short_event_id`. The only path that
--   even exposes the column (`unified_listings` → `v_market_listings_by_event`)
--   has ZERO downstream consumers.
--
-- SUPERSEDED — the cross-exchange market-tracking intent this cron was built
--   for (mig 20260515240000 §4) is now served by the WORKING path:
--   `get_event_cross_source_metrics()` reads the TEvo arm from
--   `listings_snapshots` by `event_id`, and the cross-source arm via
--   `ticketsdata_listings_snapshots → ticketsdata_event_xref (event_id) →
--   aq_event_map` — i.e. the 100%-populated 7-char `aq_short_event_id` xref
--   system, not the dead `SYS-{hex}` one (mig 20260527140000). No RPC, view,
--   or terminal surface loses data by disabling this backfill.
--
-- Consequence for open work: KANBAN A1-OPS-4 (fix the 120s timeout) and
-- B1-NEXT-61 (add the cron_should_fire() policy gate) are now obsolete — both
-- describe how to fix a cron that should not run at all.
--
-- Tombstone (not unschedule) per operator direction 2026-06-01: leaves the
-- cron.job row visible for audit / future intent review. Re-enabling is a
-- deliberate `active=true` flip, but should NOT be done without first solving
-- the timeout (A1-OPS-4) AND establishing a real reader for the column.
--
-- ## Already applied to prod  Applied via MCP 2026-06-01 (active=false).

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'listings_aq_backfill_overnight') THEN
    PERFORM cron.alter_job(
      job_id := (SELECT jobid FROM cron.job WHERE jobname = 'listings_aq_backfill_overnight'),
      active := false
    );
  END IF;
END $$;
