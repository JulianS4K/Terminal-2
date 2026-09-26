-- ============================================================================
-- Migration 20260926080000 — Exos (Bridge / D4): organizer refunds count a
--                            table as one table, not one per ticket
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_refund_finalize (patched in place, one marker)
--           R/W (inside it, via _exos_tables_release_order): exos_table_bookings,
--              exos_ticket_tiers.sold
-- Pre-reqs: 20260926040000 (exos_refund_finalize),
--           20260926050000 (exos_tier_is_table, _exos_tables_release_order)
--
-- A table tier's `sold` counts tables (mig 20260926050000). exos_refund_finalize
-- took one off the tier's sold count for every ticket it voided, so refunding
-- a table of 6 put 6 tables back on sale. Now:
--   * a voided ticket of a table tier no longer touches the tier's sold count
--     (the event house count and shared quotas still free that person's seat,
--     as before: both count people);
--   * after the voids, _exos_tables_release_order cancels every table of the
--     order whose tickets are all voided and gives each back once (unless
--     someone from it was already checked in). A partial refund that voids
--     some tickets of a table leaves the table sold.
-- When the refund empties the order, exos_refund_checkout (already
-- table-aware since 20260926050000) voids the rest and releases the tables
-- the same way; a table is only ever released once (bookings go 'cancelled').
-- Standard tiers are unchanged.
--
-- Re-run safe (skipped once the marker is present). D4 authors; applying to
-- prod is operator-gated.
-- ============================================================================

DO $$
DECLARE
  fn  regprocedure := to_regprocedure('public.exos_refund_finalize(uuid, text, text, text)');
  d   text;
  n   int;
  o1  text := E'      IF r.tier_id IS NOT NULL THEN\n        UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = r.tier_id;\n      END IF;';
  n1  text := E'      IF r.tier_id IS NOT NULL AND NOT public.exos_tier_is_table(r.tier_id) THEN\n        UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = r.tier_id;\n      END IF;';
  o2  text := E'    -- Nothing left to refund: the whole order is refunded';
  n2  text := E'    -- Tables fully voided by this refund go back on sale once (mig 20260926080000).\n    PERFORM public._exos_tables_release_order(v_req.session_id);\n\n    -- Nothing left to refund: the whole order is refunded';
BEGIN
  IF fn IS NULL THEN
    RAISE EXCEPTION 'exos_refund_finalize not present: apply 20260926040000 first';
  END IF;
  IF to_regprocedure('public._exos_tables_release_order(text)') IS NULL THEN
    RAISE EXCEPTION '_exos_tables_release_order not present: apply 20260926050000 first';
  END IF;
  d := pg_get_functiondef(fn);
  IF position('_exos_tables_release_order' in d) > 0 THEN
    RAISE NOTICE 'exos_refund_finalize: already table-aware, skipping';
    RETURN;
  END IF;
  n := (length(d) - length(replace(d, o1, ''))) / length(o1);
  IF n <> 1 THEN
    RAISE EXCEPTION 'exos_refund_finalize: expected one per-ticket tier decrement, found %', n;
  END IF;
  n := (length(d) - length(replace(d, o2, ''))) / length(o2);
  IF n <> 1 THEN
    RAISE EXCEPTION 'exos_refund_finalize: expected one whole-order block, found %', n;
  END IF;
  EXECUTE replace(replace(d, o1, n1), o2, n2);
END $$;
