-- ============================================================================
-- Migration 20260619230000 — A1-OPS-26: unbind aq-bridge venue+date-coincidence
--                            mis-binds (name-inconsistent)
--
-- Lane:     xref+macro
-- Touches:  aq_event_map (W), aq_tevo_search_attempts (W), events (R)
-- Pre-reqs: aq_name_consistent(); the aq-to-tevo-search-bridge name-overlap
--           guard (same PR) — deploy that edge fn so these don't re-bind.
--
-- Sibling of A1-OPS-24/#616. `aq-to-tevo-search-bridge` scores a candidate on
-- venue (+50) + same-date (+24) and accepted at score >= minScore with only a
-- venue-signal gate (`bestVenue >= 25`) — NO name-overlap requirement. So a
-- DIFFERENT show at the same venue/date bound with zero name match. Audit of the
-- 287 bridge-matched `aq_event_map` rows found **4** such mis-binds:
--   • "Forrest Frank" (concert)            -> Spurs@Knicks NBA Finals @ MSG
--   • "Salsa Spectacular ..."              -> LA Philharmonic @ Hollywood Bowl
--   • "90s Corridos Tour"                  -> Lupillo Rivera @ Peacock Theater
--   • "Buccaneers Season Tickets"          -> Bruno Mars @ Raymond James Stadium
--
-- This unbinds the 4 (NULL `aq_event_map.tevo_event_id`) and clears their
-- `aq_tevo_search_attempts` ledger row so the now-guarded bridge re-evaluates
-- them (correct same-name match, or left unmapped — never re-mislinked). The
-- edge-fn guard (same PR) is what prevents recurrence; this is the one-time
-- corrective sweep. Self-selecting via `NOT aq_name_consistent` over
-- bridge-matched rows only — other aq_event_map binding paths are untouched.
--
-- ✅ Applied to prod  Applied via MCP 2026-06-19 (operator-authorized, CLAUDE.md §1).
--    Post-apply verified: bridge_name_inconsistent = 0. NOTE: applied without the
--    outer BEGIN/COMMIT (apply_migration manages the transaction).
-- ============================================================================

BEGIN;

-- Capture the offending aq ids while the (wrong) binding still exists.
CREATE TEMP TABLE _a1ops26_bad ON COMMIT DROP AS
SELECT m.id AS aq_id
FROM public.aq_tevo_search_attempts a
JOIN public.aq_event_map m ON m.id = a.aq_id
JOIN public.events e ON e.id = m.tevo_event_id
WHERE a.result = 'matched'
  AND m.tevo_event_id IS NOT NULL
  AND NOT public.aq_name_consistent(e.name, m.event_name);

-- Clear the stale 'matched' ledger rows so the bridge re-attempts under the guard.
DELETE FROM public.aq_tevo_search_attempts a
USING _a1ops26_bad b
WHERE a.aq_id = b.aq_id;

-- Unbind the mis-bound hub rows (NULL the tevo link only; never delete the row).
UPDATE public.aq_event_map m
SET tevo_event_id = NULL
FROM _a1ops26_bad b
WHERE m.id = b.aq_id;

COMMIT;
