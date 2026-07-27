-- ============================================================================
-- MIG 20260629210000 — APPLY aq_event_map safe-class dedupe (A1-OPS-22, demo prep)
--
-- Context: terminal demo prep. The marquee demo event UFC 329 (tevo 3350088,
-- "McGregor vs Holloway") carries TWO system_seed aq_event_map rows
-- (SYS-aee24c7f45 + SYS-bf1beddbe5) that resolve to the SAME game — same
-- sg_event_id (18158636), same venue_short_id (LNVAFF1), one holds the
-- tm_event_id. Two hub rows -> one tevo_event_id risks DOUBLE-COUNTING the
-- SeatGeek leg in the event page's cross-source listing panel.
--
-- Fix: invoke the already-installed, reviewed, FK-safe consolidation function
-- public.aq_consolidate_safe_dups (installed mig 20260608201500). It NEVER
-- deletes (8 FK-dependents), only COALESCEs loser platform ids onto the richest
-- survivor, re-points ticketsdata_event_xref, and NULLs loser ids. It handles
-- ONLY the SAFE class (no platform-id conflict); the ~conflicting doubleheader/
-- parking clusters are deliberately excluded and untouched.
--
-- Dry-run preview captured 2026-06-29 (read-only, p_apply=>false):
--   225 consolidations across 217 distinct tevo_event_ids, INCLUDING UFC 329.
--   The clean Yankees / AXS demo events have a single aq row each (untouched).
--
-- This migration is IDEMPOTENT + re-runnable: once a cluster is consolidated it
-- is no longer a dup, so a second apply is a no-op (0 rows affected).
--
-- ⚠ MUTATES public.aq_event_map (+ ticketsdata_event_xref re-points). Per RULE 1
--   this is gated: A1 applies. NOT auto-applied by authoring this file.
--   Verify first:  SELECT action, count(*)
--                    FROM public.aq_consolidate_safe_dups(false) GROUP BY 1;
-- ============================================================================

DO $body$
DECLARE
  v_count int;
BEGIN
  -- execute the consolidation (p_apply => true) and count what was consolidated
  SELECT count(*) INTO v_count
  FROM public.aq_consolidate_safe_dups(true);

  RAISE NOTICE 'aq_consolidate_safe_dups applied: % loser rows consolidated', v_count;
END
$body$;
