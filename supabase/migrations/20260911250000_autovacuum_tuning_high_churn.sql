-- Already applied to prod · via MCP 2026-09-11 under operator direction.
-- Migration 20260911250000 · level:data-collection · lane:A1 · writes:gotickets_listings_snapshots(reloptions),event_section_row_snapshots(reloptions),ticketsdata_listings_snapshots(reloptions) · reads:none · pre:20260705153000
--
-- ============================================================================
-- Migration 20260911250000 — autovacuum tuning for the untuned high-churn tables
--
-- Lane:     A1 (data plane — retention/vacuum)
-- Touches:  reloptions only on gotickets_listings_snapshots,
--           event_section_row_snapshots, ticketsdata_listings_snapshots.
--           NO data, NO schema, NO locks beyond a brief ALTER TABLE.
-- Pre-reqs: 20260705153000 (retention_tick — the delete volume this answers)
--
-- ── THE GAP ────────────────────────────────────────────────────────────────
-- Measured on prod 2026-09-11 21:15 UTC. Three snapshot tables already carry
-- per-table autovacuum tuning; the rest sit on the 0.2 (20%) cluster default.
-- The correlation with dead-tuple load is exact:
--
--   table                          tuned   dead_tup      dead%
--   listings_snapshots             0.02     1,297,386     0.7
--   section_metrics                0.02     1,438,085     0.8
--   seatgeek_listings_snapshots    0.02           148     0.1
--   gotickets_listings_snapshots   NONE    19,314,382    12.5   <-- 130 GB table
--   event_section_row_snapshots    NONE        34,854     0.3
--   ticketsdata_listings_snapshots NONE       229,528     0.9
--
-- gotickets_listings_snapshots is the highest-churn table in the database —
-- retention_tick deletes ~15M rows/day from it (retention_policy.last_deleted
-- 212,514 per tick, total_deleted 521M) — and it is the one high-churn table
-- without the tuning its siblings have. At scale_factor 0.2 autovacuum does
-- not trigger until ~27M dead tuples (20% of 135M live); at 0.02 it triggers
-- at ~2.7M. That single default is why it carries 19.3M dead tuples (~12 GB
-- of dead heap at its measured ~0.64 KB/row) while listings_snapshots, under
-- comparable churn, holds 1.3M.
--
-- Values are COPIED VERBATIM from the already-proven sibling config (see
-- pg_class.reloptions on listings_snapshots / section_metrics /
-- seatgeek_listings_snapshots) — this is not a new tuning theory, it closes a
-- gap where three tables got the treatment and three did not.
--
-- ── WHAT THIS DOES NOT DO ──────────────────────────────────────────────────
-- This bounds FUTURE dead-tuple growth. It does NOT return already-bloated
-- space to the OS — plain autovacuum never shrinks a heap file. The 19.3 GB
-- already dead in gotickets becomes reusable free space inside the existing
-- file (so the table stops growing), but the file stays 130 GB.
-- Reclaiming existing bloat needs VACUUM FULL / pg_repack and is a separate,
-- lock-taking operator decision — deliberately not bundled here.
-- In particular the ~74 GB of dead space in ticketsdata_listings_snapshots
-- (95 GB heap holding ~21 GB live; writers dark since 2026-09-09, vendor
-- contract lapsed per KANBAN A1-OPS-33) is NOT addressed by this migration.
--
-- Reversible: ALTER TABLE ... RESET (autovacuum_vacuum_scale_factor, ...).
-- Idempotent: SET on reloptions is last-write-wins; re-apply is a no-op.
-- ============================================================================

ALTER TABLE public.gotickets_listings_snapshots SET (
  autovacuum_vacuum_scale_factor        = 0.02,
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_analyze_scale_factor       = 0.02
);

ALTER TABLE public.event_section_row_snapshots SET (
  autovacuum_vacuum_scale_factor        = 0.02,
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_analyze_scale_factor       = 0.02
);

ALTER TABLE public.ticketsdata_listings_snapshots SET (
  autovacuum_vacuum_scale_factor        = 0.02,
  autovacuum_vacuum_insert_scale_factor = 0.05,
  autovacuum_analyze_scale_factor       = 0.02
);

-- Self-check: all six snapshot tables now carry the same tuning.
DO $do$
DECLARE v_missing text;
BEGIN
  SELECT string_agg(c.relname, ', ') INTO v_missing
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN ('gotickets_listings_snapshots','event_section_row_snapshots',
                      'ticketsdata_listings_snapshots','listings_snapshots',
                      'section_metrics','seatgeek_listings_snapshots')
    AND NOT coalesce(array_to_string(c.reloptions, ',') LIKE '%autovacuum_vacuum_scale_factor=0.02%', false);

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'still untuned after this migration: %', v_missing;
  END IF;
END $do$;
