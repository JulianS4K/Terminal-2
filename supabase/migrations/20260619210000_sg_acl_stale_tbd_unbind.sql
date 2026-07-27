-- ============================================================================
-- Migration 20260619210000 — unbind stale mis-bound SG rows (A1-OPS-24 follow-up)
--   Part A: 9 stale TBD off-date auto_canonical_loop bindings
--   Part B: 2 cross-event name-inconsistent bindings (shared venue/date, wrong show)
--
-- Lane:     xref+macro
-- Touches:  seatgeek_event_xref (W), sg_events_canonical (W), events (R)
-- Pre-reqs: 20260619200000 (A1-OPS-24 exact-date guard — the v3 cron that
--           re-evaluates these after unbind), aq_name_consistent()
--
-- FOLLOW-UP to A1-OPS-24 (#613). The exact-date sweep cleared 35 series
-- mis-binds in the v3 matcher path. A residual 9 off-date bindings remained,
-- all tagged match_method='auto_canonical_loop' — written by the LEGACY v1 loop
-- auto_match_sg_canonical() (now UNSCHEDULED; no cron references it). These are
-- NFL/NBA TBD-placeholder events (away side = "TBD"): at bind time the dates
-- matched, then the SG-side date drifted to a default (e.g. 2026-08-11) while
-- the binding persisted via the existing-xref early-return. Examples:
--   • "NFL Preseason G1 - TBD at Philadelphia" SG 08-11 -> a Bengals game 08-28 (17d)
--   • "NFL Preseason G2 - TBD at Las Vegas"     SG 08-18 -> a 49ers game   08-27 ( 9d)
--   • "Oklahoma City Thunder at San Antonio Spurs" SG 05-20 -> 05-22 (2d, playoff)
--
-- The v1 binder is dead (its matcher even requires an exact date, so it cannot
-- re-create these), so a one-time unbind is permanent. After clearing, the
-- guarded hourly auto_match_sg_canonical_v3 cron re-maps each to the correct
-- same-date event once the league finalizes the matchup; until then they sit
-- unmapped — correct for a TBD placeholder.
--
-- Scope (Part A) is surgical: ONLY auto_canonical_loop rows whose bound TEvo date
-- differs from the SG date. The 1,392 on-date auto_canonical_loop bindings are
-- untouched.
--
-- Part B — cross-event name-inconsistent unbind. Two same-venue/same-date binds
-- to a DIFFERENT show that the A1-OPS-23 name guard would reject but which slipped
-- through guard-less binders (these are the exact examples cited in A1-OPS-23,
-- recurred):
--   • "TBD at Colorado Avalanche (NHL)" -> "TBD at Denver Nuggets (NBA)"  Ball Arena
--     (auto_canonical_loop; v1 path, now dead — won't recur)
--   • "Salsa Spectacular ..."           -> "Los Angeles Philharmonic ..."  Hollywood Bowl
--     (tevo_search_owned_priority; this binder lacks a name guard — see KANBAN
--      follow-up to port aq_name_consistent into the tevo_search binders; this
--      unbind clears the live wrong-inventory display in the meantime)
-- Detector is self-selecting (NOT aq_name_consistent) and permissive-by-default,
-- so it only ever touches genuinely-inconsistent rows.
--
-- ✅ Applied to prod  Applied via MCP 2026-06-19 (operator-authorized, CLAUDE.md §1).
--    Post-apply verified: Part A acl_offdate_remaining=0 (9 nulled), on_date count
--    unchanged; Part B name_inconsistent_remaining=0 (2 nulled). NOTE: applied
--    without the outer BEGIN/COMMIT (apply_migration manages the transaction).
-- ============================================================================

BEGIN;

-- Delete the xref rows for the 9 stale off-date auto_canonical_loop bindings.
DELETE FROM public.seatgeek_event_xref x
USING public.sg_events_canonical sgc
JOIN public.events e ON e.id = sgc.tevo_event_id
WHERE x.sg_event_id = sgc.sg_event_id
  AND sgc.match_method = 'auto_canonical_loop'
  AND sgc.tevo_event_id IS NOT NULL
  AND e.occurs_at_local::date <> sgc.sg_event_date;

-- Null the canonical rows so the v3 cron re-evaluates them under the new guard.
UPDATE public.sg_events_canonical sgc
SET tevo_event_id    = NULL,
    match_method     = 'a1ops24_acl_tbd_unbind',
    match_confidence = NULL,
    matched_at       = NULL,
    updated_at       = now()
FROM public.events e
WHERE e.id = sgc.tevo_event_id
  AND sgc.match_method = 'auto_canonical_loop'
  AND sgc.tevo_event_id IS NOT NULL
  AND e.occurs_at_local::date <> sgc.sg_event_date;

-- ── Part B: cross-event name-inconsistent unbind (any binder) ───────────────
DELETE FROM public.seatgeek_event_xref x
USING public.sg_events_canonical sgc
JOIN public.events e ON e.id = sgc.tevo_event_id
WHERE x.sg_event_id = sgc.sg_event_id
  AND sgc.tevo_event_id IS NOT NULL
  AND NOT public.aq_name_consistent(e.name, sgc.sg_event_name);

UPDATE public.sg_events_canonical sgc
SET tevo_event_id    = NULL,
    match_method     = 'a1ops24_nameguard_unbind',
    match_confidence = NULL,
    matched_at       = NULL,
    updated_at       = now()
FROM public.events e
WHERE e.id = sgc.tevo_event_id
  AND sgc.tevo_event_id IS NOT NULL
  AND NOT public.aq_name_consistent(e.name, sgc.sg_event_name);

COMMIT;
