-- ============================================================================
-- Migration 20260623190200 — validate the NOT VALID foreign-key backlog
--
-- Lane:     A1 (constraints / data plane)
-- Touches:  VALIDATE CONSTRAINT on all public NOT VALID foreign keys (54 at
--           authoring time). No schema shape change; no data mutation.
-- Pre-reqs: none. Idempotent — re-running only touches still-NOT-VALID FKs.
-- Apply:    APPLIED to prod 2026-06-23 (operator-authorized), but NOT via this
--           single DO — the all-in-one transaction exceeds the 60s MCP gateway
--           (the client reset rolls the whole txn back). Instead run in size-
--           bounded batches that each commit independently:
--             1) one DO over all FKs on tables < ~700k rows  -> 54 -> 13
--             2) espn_athlete_team_history (2.5M) x2          -> -> 11
--             3) seatgeek_sales/listings_snapshots (13M/17M) one VALIDATE per
--                call (each ~60-120s; commits just past the client cutoff) -> 5
--           Result: 54 -> 5. The 5 left are orphan-bearing and were skipped:
--             performer_wikipedia (152/746) + seatgeek_performer_xref (31/132)
--               -> performer_metadata(performer_id)
--             seatgeek_orders_resolved (2/271) + seatgeek_venue_xref (4/38)
--               + venue_pulls (1/3) -> venue_assets(tevo_venue_id)
--           These FKs reference COVERAGE tables (performer_metadata/venue_assets),
--           not the entity tables — likely a mis-targeted parent. A1 data call:
--           repoint to the entity table, backfill coverage, or prune orphans.
--           VALIDATE takes only SHARE UPDATE EXCLUSIVE → never blocks reads/writes.
--           (This DO remains correct for a future direct-psql run with no gateway.)
--
-- ── BACKGROUND ──────────────────────────────────────────────────────────────
--   release_health_check() → fks.not_valid_fks = warn (metric 54). These FKs
--   were added `NOT VALID` (the standard way to attach an FK to a large table
--   without a long ACCESS EXCLUSIVE lock): they enforce on NEW rows but the
--   pre-existing rows were never validated, so the catalog flag never cleared.
--   Spot-check (event_alerts, vivid_orders, seatgeek_orders) found NO orphans,
--   so most should validate cleanly.
--
-- ── APPROACH ────────────────────────────────────────────────────────────────
--   Iterate every NOT VALID FK in `public` and VALIDATE each in its OWN
--   subtransaction (EXCEPTION = savepoint). A constraint that DOES have orphans
--   raises on VALIDATE; we catch it, RAISE NOTICE the constraint + table, and
--   leave it NOT VALID for targeted data cleanup — one bad FK can't abort the
--   batch. statement_timeout is disabled (own statement, see below) so a large-
--   table scan can't trip the role default mid-batch; VALIDATE's lock is
--   non-blocking, so this is safe to run live.
--
--   ⚠ Large target tables (full scan on VALIDATE): listings_snapshots (~8M),
--   seatgeek_listings_snapshots, ticketsdata_*-keyed, seatdata_*-keyed. Expect
--   minutes, not seconds, for those. Run when load permits.
-- ============================================================================

-- Disable statement_timeout for THIS migration session as its own statement so
-- the DO block below inherits it (a SET inside the DO would not re-arm the timer).
SET statement_timeout = '0';

DO $$
DECLARE
  r           record;
  v_validated int := 0;
  v_skipped   int := 0;
BEGIN
  FOR r IN
    SELECT con.conname, rel.relname
    FROM pg_constraint con
    JOIN pg_class     rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE con.contype = 'f'
      AND NOT con.convalidated
      AND nsp.nspname = 'public'
    ORDER BY rel.relname, con.conname
  LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT %I', r.relname, r.conname);
      v_validated := v_validated + 1;
      RAISE NOTICE 'validated %.%', r.relname, r.conname;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'SKIP %.% — has orphans or errored: %', r.relname, r.conname, SQLERRM;
    END;
  END LOOP;
  RAISE NOTICE 'done: % validated, % skipped (still NOT VALID)', v_validated, v_skipped;
END $$;

-- ── VERIFICATION (run after apply) ──────────────────────────────────────────
--   SELECT status, metric, detail FROM public.release_health_check()
--    WHERE check_name = 'not_valid_fks';
--   -- metric should drop to 0 (status 'ok') if all validated; any remaining are
--   -- the skipped, orphan-bearing FKs that need data cleanup first.
-- ============================================================================
