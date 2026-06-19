-- Migration 20260619220000 · lane:A1 (operator-directed) · ⚠ BLUEPRINT — DO NOT AUTO-APPLY
--   writes (DDL): converts listings_snapshots (48 GB / 123 M rows) to a RANGE-
--     partitioned table by captured_at, WITHOUT a 123 M-row copy (attach the
--     existing table as the historical partition).
--   reads: none
--
-- ## STATUS: NOT APPLIED — operator-gated AND staged. This is a RUNBOOK, not a
-- one-shot migration. Each STAGE is run + verified MANUALLY, in a maintenance
-- window, by A1. Do NOT pipe this whole file through apply_migration.
--
-- WHY (operator reframe 2026-06-19, primary concern = analysis SPEED):
--   * Time-window analysis seq-scans 123 M rows because a plain table can't
--     prune by captured_at. min(captured_at) over the raw table TIMED OUT @25s.
--   * Retention today is DELETE-based -> 415 M lifetime deletes -> 22 GB of
--     bloated btrees that never shrink -> every scan reads more pages -> the
--     table keeps RE-bloating. Partitioning makes retention `DROP PARTITION`
--     (instant, zero dead tuples, no VACUUM) so speed STAYS won, not just won once.
--   Full analysis: docs/archive/2026-06-19-snapshot-bloat-play.md (§"Speed solution" pillar 4).
--
-- FEASIBILITY (verified 2026-06-19): captured_at is NOT NULL, is in the PK
-- (event_id, captured_at, tevo_ticket_group_id), and the table has 0 inbound
-- FKs — all three preconditions for range-partitioning by captured_at hold.
--
-- KEY TRICK — no big copy: instead of creating a partitioned table and copying
-- 123 M rows in, we ATTACH the *existing* table as the historical partition.
-- A pre-validated CHECK constraint lets ATTACH skip the full-table scan, so the
-- cutover is metadata-fast. New rows land in fresh monthly partitions.
--
-- PRECONDITIONS BEFORE STARTING:
--   * Maintenance window with the listings ingest writers PAUSED (collect-listings
--     crons) — see the SG-pause pattern in the play doc; pause the TEvo listings
--     collectors the same way (cron.alter_job active:=false), resume in STAGE 6.
--   * A verified backup / PITR checkpoint. This reshapes the central firehose.
--   * Confirm NO SECDEF RPC or view references listings_snapshots by a name that
--     a rename would break mid-window (grep pg_proc + view defs first; the parent
--     keeps the canonical name `listings_snapshots` at the end, so steady-state
--     reads are unaffected — only the in-window rename is sensitive).

-- ════════════════════════════════════════════════════════════════════════════
-- STAGE 1 — build the partitioned parent (empty). Fast, online, no data move.
-- Run; verify the parent + PK exist; then STAGE 2.
-- ════════════════════════════════════════════════════════════════════════════
-- Clone column shape (types, NOT NULLs, defaults) from the live table, then make
-- it partitioned. LIKE keeps us faithful to the real schema (splits int4[],
-- is_ancillary/is_owned NOT NULL DEFAULT false, etc.) without hand-transcribing.
CREATE TABLE public.listings_snapshots_part
  (LIKE public.listings_snapshots INCLUDING DEFAULTS)
  PARTITION BY RANGE (captured_at);

-- PK must include the partition key (it does). Add explicitly on the parent.
ALTER TABLE public.listings_snapshots_part
  ADD CONSTRAINT listings_snapshots_part_pkey
  PRIMARY KEY (event_id, captured_at, tevo_ticket_group_id);

-- Re-create the hot read indexes on the parent (propagate to all partitions).
CREATE INDEX listings_snapshots_part_captured_idx
  ON public.listings_snapshots_part (captured_at);
CREATE INDEX listings_snapshots_part_event_time_idx
  ON public.listings_snapshots_part (event_id, captured_at DESC);
CREATE INDEX listings_snapshots_part_event_tgid_captured_idx
  ON public.listings_snapshots_part (event_id, tevo_ticket_group_id, captured_at DESC);
CREATE INDEX listings_snapshots_part_owned_idx
  ON public.listings_snapshots_part (event_id, captured_at) WHERE (is_owned = true);

-- ════════════════════════════════════════════════════════════════════════════
-- STAGE 2 — pre-validate a CHECK on the existing table so ATTACH skips the scan.
-- Pick CUTOVER = the start of the next month boundary AFTER `now()` at run time.
-- Example below uses 2026-07-01; SUBSTITUTE the real boundary when you run it.
-- ADD ... NOT VALID is instant (no scan); VALIDATE scans once (minutes, SHARE
-- UPDATE EXCLUSIVE — concurrent reads/writes still allowed) but no rewrite.
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.listings_snapshots
  ADD CONSTRAINT listings_snapshots_hist_ck
  CHECK (captured_at < TIMESTAMPTZ '2026-07-01 00:00:00+00') NOT VALID;
ALTER TABLE public.listings_snapshots
  VALIDATE CONSTRAINT listings_snapshots_hist_ck;
-- VERIFY: SELECT convalidated FROM pg_constraint WHERE conname='listings_snapshots_hist_ck'; -- must be true

-- ════════════════════════════════════════════════════════════════════════════
-- STAGE 3 — create the forward partitions the writers will land in (one per
-- month is plenty given 15 d retention). Empty -> instant.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.listings_snapshots_p2026_07 PARTITION OF public.listings_snapshots_part
  FOR VALUES FROM ('2026-07-01+00') TO ('2026-08-01+00');
CREATE TABLE public.listings_snapshots_p2026_08 PARTITION OF public.listings_snapshots_part
  FOR VALUES FROM ('2026-08-01+00') TO ('2026-09-01+00');

-- ════════════════════════════════════════════════════════════════════════════
-- STAGE 4 — CUTOVER. Single short transaction in the maintenance window with
-- writers paused. Rename old -> hist, attach it as the historical partition
-- (fast: CHECK already validated), rename parent into the canonical name.
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
  ALTER TABLE public.listings_snapshots RENAME TO listings_snapshots_hist;
  -- attach the whole historical table as the [MINVALUE, 2026-07-01) partition.
  ALTER TABLE public.listings_snapshots_part
    ATTACH PARTITION public.listings_snapshots_hist
    FOR VALUES FROM (MINVALUE) TO ('2026-07-01+00');
  -- the partitioned parent now owns the canonical name the app/RPCs read.
  ALTER TABLE public.listings_snapshots_part RENAME TO listings_snapshots;
COMMIT;
-- VERIFY (still in window): partition list + a pruned plan.
--   SELECT inhrelid::regclass FROM pg_inherits
--     WHERE inhparent='public.listings_snapshots'::regclass;
--   EXPLAIN SELECT count(*) FROM public.listings_snapshots
--     WHERE captured_at >= now() - interval '2 days';  -- must show partition pruning

-- ════════════════════════════════════════════════════════════════════════════
-- STAGE 5 — drop the now-redundant CHECK on the historical partition (the
-- partition bound already enforces it; keeping it just double-scans).
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.listings_snapshots_hist DROP CONSTRAINT listings_snapshots_hist_ck;

-- ════════════════════════════════════════════════════════════════════════════
-- STAGE 6 — resume the paused listings ingest crons (cron.alter_job active:=true).
-- Then schedule the maintenance cron below.
-- ════════════════════════════════════════════════════════════════════════════
-- ONGOING MAINTENANCE (REQUIRED — a partitioned table needs a partition-maker +
-- retention dropper, else inserts past the last partition FAIL). Author as a
-- monthly pg_cron job (separate migration once this lands):
--   * pre-create next month's partition (idempotent CREATE ... IF NOT EXISTS pattern);
--   * DROP PARTITION older than retention (e.g. 60 d) — replaces the DELETE sweep.
-- Until that cron exists, inserts beyond 2026-08-31 will error. DO NOT cut over
-- without it staged.

-- ════════════════════════════════════════════════════════════════════════════
-- ROLLBACK (before STAGE 4 commit): just COMMIT nothing / DROP TABLE
-- listings_snapshots_part (empty) and DROP the hist CHECK — the live table is
-- untouched until the STAGE 4 rename. AFTER STAGE 4: detach + rename back:
--   ALTER TABLE public.listings_snapshots RENAME TO listings_snapshots_part;
--   ALTER TABLE public.listings_snapshots_part DETACH PARTITION public.listings_snapshots_hist;
--   ALTER TABLE public.listings_snapshots_hist RENAME TO listings_snapshots;
--   DROP TABLE public.listings_snapshots_part;   -- only the new (forward) partitions are lost
-- ════════════════════════════════════════════════════════════════════════════
