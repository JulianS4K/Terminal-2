-- ============================================================================
-- Migration 20260703123000 — Exos (Bridge / D4): retract an announcement
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_event_announcements (RLS: +staff DELETE policy + GRANT DELETE)
-- Pre-reqs: 20260703121000 (exos_event_announcements).
--
-- Fleshes out the announcements feature: owner/manager (or admin) can retract an
-- announcement they posted, removing it from the in-app "Updates from the
-- organizer" thread on holders' tickets. (Emails already queued/sent can't be
-- recalled — this pulls the persisted in-app record only.) Buyers/holders keep
-- SELECT-only; there is no holder DELETE. Delete goes straight through RLS (no
-- RPC needed — no fan-out or counter to keep consistent, unlike the send path).
--
-- D4 authors; A1 applies.
-- ============================================================================

CREATE POLICY exos_event_announcements_staff_del ON public.exos_event_announcements
  FOR DELETE TO authenticated
  USING (
    exos_is_admin()
    OR exos_has_org_role(org_id, ARRAY['owner','manager'])
  );

GRANT DELETE ON public.exos_event_announcements TO authenticated;
