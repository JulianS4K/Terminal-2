-- Migration 20261122040000 · level:ops · lane:A1 (data plane — retention engine, KANBAN A1-DATA-1 P1 / A1-DB-7) · writes:ticketsdata_listings_snapshots(TRUNCATE: 0 live rows, 34 GB of dead pages) · reads:— · pre:—
--
-- TICKETSDATA LISTINGS SNAPSHOTS — THE 34 GB OF NOTHING GOES.
--
-- Operator 2026-11-22 ("Truncate TD table first, then apply" — the headroom for the GoTickets rebuild, mig
-- 20261122030000, whose new table sits beside the 130 GB old heap until the drop). `ticketsdata_listings_snapshots`
-- has held 0 live rows since the TicketsData path was retired (the retention policy's sweep has found nothing for
-- 27 runs; pg_stat shows 0 live / 0 dead tuples; last autovacuum 2026-10-09) but its heap and indexes are still
-- 34 GB of pages a DELETE could never give back. TRUNCATE unlinks them: seconds, no row lost — there is none.
--
-- Checked before authoring (2026-11-22 03:5xZ, read-only): no row (LIMIT 1 probe), no foreign key references it, no
-- function inserts into it, no active cron names it. The table, its indexes, grants, policy row and the views on it
-- stay as they are; only the storage goes.
--
-- Apply: `BEGIN;` / `COMMIT;` stripped (the tool wraps its own); any minute.

BEGIN;
SET LOCAL lock_timeout = '30s';

DO $t$
BEGIN
  IF EXISTS (SELECT 1 FROM public.ticketsdata_listings_snapshots LIMIT 1) THEN
    RAISE EXCEPTION 'td_snapshots_truncate: ticketsdata_listings_snapshots is not empty — not truncating';
  END IF;
  TRUNCATE TABLE public.ticketsdata_listings_snapshots;
END $t$;

COMMIT;
