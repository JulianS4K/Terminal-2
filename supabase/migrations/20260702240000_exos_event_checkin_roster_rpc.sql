-- ============================================================================
-- Migration 20260702240000 — Exos (Bridge / D4): single-call offline check-in
--                            roster RPC (one org-role check, not per-row)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  NEW public.exos_event_checkin_roster(uuid)
-- Pre-reqs: 20260520130000 (exos_tickets + exos_has_org_role + exos_is_admin),
--           20260520120000 (exos_profiles),
--           20260702123000 (barcode_secret least-privilege — this RPC is the
--                           bulk door-staff read that mirrors that fix's
--                           owner/manager/scanner gate, checked ONCE here)
--
-- WHY. The door app's offline registry (OrganizerCheckIn →
-- listEventTicketsForRegistry) fanned out to THREE reads per open:
--   1. exos_tickets            — RLS exos_tickets_sel re-evaluates
--                                exos_has_org_role() PER ROW,
--   2. exos_ticket_barcode_secrets — the mig 20260702123000 view re-evaluates
--                                exos_can_read_ticket_secret() (a per-row
--                                SECURITY DEFINER subquery over exos_tickets)
--                                PER ROW,
--   3. exos_profiles           — owner display names.
-- On a large event (measured: 5k tickets → ~133 ms just for step 1, and step 2
-- is strictly worse — a correlated per-row function) that is O(N) SECURITY
-- DEFINER evaluations across two round-trips before the door can go offline.
--
-- This RPC collapses all three into ONE SECURITY DEFINER call that authorizes
-- the whole roster with a SINGLE exos_has_org_role() check, then returns the
-- rows in one scan (owner name joined, secret included). Authorization is
-- identical to the per-row path — owner/manager/scanner (the door roles) or
-- admin, deliberately NOT finance/content, matching exos_can_read_ticket_secret
-- from mig 20260702123000. No privilege is widened: door staff already could
-- read every secret for the event via that view; this just stops paying the
-- per-row cost. Owner/buyer self-serve secret reads keep using the view.
--
-- Read-only (STABLE). No data changes. Idempotent (CREATE OR REPLACE).
--
-- ⚠ B1 review requested on the read gate before prod apply (bulk secret read
-- surface). D4 authors; validate on a Supabase preview branch; A1 applies.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_event_checkin_roster(p_event_id uuid)
RETURNS TABLE (
  ticket_id           uuid,
  status              text,
  owner_id            uuid,
  owner_name          text,
  tier_name           text,
  barcode_secret      text,
  promoter_id         text,
  pending_transfer_id uuid
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: event not found';
  END IF;

  -- ONE authorization check for the entire roster. Door roles only (mirrors
  -- exos_can_read_ticket_secret, mig 20260702123000): owner/manager/scanner or
  -- platform admin. Finance/content are deliberately excluded — they must never
  -- read barcode_secret in bulk (the whole point of the least-privilege fix).
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: not authorized for this event'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT t.id, t.status, t.owner_id, p.display_name, t.tier_name,
           t.barcode_secret, t.promoter_id, t.pending_transfer_id
    FROM public.exos_tickets t
    LEFT JOIN public.exos_profiles p ON p.id = t.owner_id
    WHERE t.event_id = p_event_id;
END $$;

REVOKE EXECUTE ON FUNCTION public.exos_event_checkin_roster(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_event_checkin_roster(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_checkin_roster(uuid) TO authenticated, service_role;

-- ROLLBACK: DROP FUNCTION IF EXISTS public.exos_event_checkin_roster(uuid);
