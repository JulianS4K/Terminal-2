-- ============================================================================
-- Migration 20260911235000 — give the GoTickets firehose the autovacuum settings EVO has
-- Migration 20260911235000 · level:data-collection · lane:A1 · writes:gotickets_listings_snapshots(reloptions),event_section_row_snapshots(reloptions) · reads:pg_class,pg_stat_user_tables · pre:20260804230000
--
-- Lane:     A1 (data plane)
-- Touches:  gotickets_listings_snapshots (ALTER .. SET storage params),
--           event_section_row_snapshots (same)
-- Pre-reqs: 20260804230000 (GT listings firehose + its retention policy)
--
-- gotickets_listings_snapshots is the largest object in the database at 130 GB
-- (87 GB heap + 43 GB indexes) and it should not be. Measured against the EVO
-- firehose it is the same shape of table doing LESS work:
--
--              EVO listings_snapshots   GT gotickets_listings_snapshots
--   polls/event/day        4.6                    4.4
--   rows ingested 24h     15.1M                   5.9M
--   live row width        147 B                   128 B
--   heap                   35 GB                  87 GB
--   heap bytes/row          207                    683      <-- ~3.3x
--   dead tuples       1.3M (0.7%)            19.3M (12.5%)
--   autovacuum runs         201                     58
--
-- ~21 GB of live data in an 87 GB heap: roughly 65 GB is dead space that was
-- never reclaimed. The cause is not cadence and not row width — it is that
-- when the GT firehose landed (20260804230000) it was given a retention policy
-- mirroring listings_snapshots but NOT the per-table autovacuum settings that
-- make that table sustainable:
--
--   listings_snapshots : autovacuum_vacuum_scale_factor=0.02,
--                        autovacuum_vacuum_insert_scale_factor=0.05,
--                        autovacuum_analyze_scale_factor=0.02
--   gotickets_listings_snapshots : (none — cluster defaults, 0.2)
--
-- At the 0.2 default GT must accumulate 0.2 * 137M = ~27.4M dead tuples before
-- autovacuum will touch it. It is sitting at 19.3M, so it does not trigger —
-- while retention_tick deletes ~15M rows/day into space that is never reused.
-- EVO at 0.02 triggers around 3.7M and stays clean. GT has deleted MORE rows
-- than EVO in total (764M vs 427M) on less than a third of the vacuums.
--
-- This migration is the parity fix: same three settings, same values, chosen to
-- match the table that demonstrably works rather than invented here.
--
-- SCOPE NOTE — what this does and does not do. Plain autovacuum marks dead
-- space REUSABLE; it does not return it to the OS. So the effect is that GT
-- stops growing and future inserts refill the existing 87 GB, not that the
-- file shrinks. Reclaiming the ~65 GB outright needs VACUUM FULL (ACCESS
-- EXCLUSIVE lock + a second copy of the table on disk — not safe to run from a
-- migration on a 411 GB instance) or pg_repack. That is an operator decision
-- and is deliberately NOT done here.
--
-- event_section_row_snapshots has the identical omission (20% dead, 6.2 GB) and
-- gets the same treatment.
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

COMMENT ON TABLE public.gotickets_listings_snapshots IS
  'GoTickets Pro-API listings firehose. 15d retention (20260804230000) + '
  'autovacuum parity with listings_snapshots (20260911235000): at the cluster '
  'default 0.2 scale factor this table never reached its vacuum threshold and '
  'grew to an 87 GB heap holding ~21 GB of live rows.';
