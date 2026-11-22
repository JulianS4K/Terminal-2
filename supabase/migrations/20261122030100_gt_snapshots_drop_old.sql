-- Migration 20261122030100 · level:ops · lane:A1 (data plane — retention engine, KANBAN A1-DATA-1 P1 / A1-DB-7) · writes:gotickets_listings_snapshots_old(dropped) · reads:gt_snapshots_rebuild · pre:20261122030000
--
-- GOTICKETS LISTINGS FIREHOSE — THE OLD HEAP GOES. This is the reclaim (~130 GB on 2026-11-22).
--
-- Apply ONLY after the rebuild (mig 20261122030000) reports phase 'done' in v_gt_snapshots_rebuild and the operator
-- has compared the two tables (row counts inside the window, the deal-evidence rows, a few events' latest captures).
-- The guard below refuses otherwise. Nothing reads or writes gotickets_listings_snapshots_old after the swap.
--
-- Apply: `BEGIN;` / `COMMIT;` stripped; any minute (DROP TABLE is metadata + file unlink — seconds).

BEGIN;
SET LOCAL lock_timeout = '30s';

DO $drop$
DECLARE v_phase text;
BEGIN
  SELECT phase INTO v_phase FROM public.gt_snapshots_rebuild WHERE id = 1;
  IF v_phase IS DISTINCT FROM 'done' THEN
    RAISE EXCEPTION 'gt_snapshots_drop_old: the rebuild is in phase % — not dropping anything', coalesce(v_phase, '(no state row)');
  END IF;
  IF to_regclass('public.gotickets_listings_snapshots_old') IS NULL THEN
    RAISE NOTICE 'gt_snapshots_drop_old: nothing to drop';
    RETURN;
  END IF;
  DROP TABLE public.gotickets_listings_snapshots_old;
  RAISE NOTICE 'gt_snapshots_drop_old: dropped public.gotickets_listings_snapshots_old';
END $drop$;

COMMIT;
