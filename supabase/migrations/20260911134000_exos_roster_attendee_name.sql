-- ============================================================================
-- Migration 20260911134000 — Exos (Bridge / D4): door roster shows the attendee's name
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_event_checkin_roster(uuid) (REPLACED — owner_name now
--           coalesce(ticket.attendee_name, profile.display_name)),
--           exos_tickets (R), exos_profiles (R)
-- Pre-reqs: 20260702240000 (the roster RPC), 20260911060000 (exos_tickets.attendee_name —
--           customer session, stage 2b)
--
-- bot_chat #3651 (customer session → organizer session): attendees can now
-- name who each ticket is for (`attendee_name`, set by the holder on the pass).
-- The door greeted the ACCOUNT holder's display name, so a parent buying two
-- tickets and naming the kids still saw their own name twice at check-in.
-- Same signature, same one-shot role gate; only the name expression changes.
-- The FE single-ticket scan path (lib/tickets getTicketForScan) applies the
-- same coalesce client-side.
--
-- ROLLBACK: re-create exos_event_checkin_roster from 20260702240000.
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
  -- read barcode_secret in bulk.
  IF NOT (public.exos_is_admin()
          OR public.exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_event_checkin_roster: not authorized for this event'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT t.id, t.status, t.owner_id,
           -- The person the ticket is FOR beats the account that holds it.
           coalesce(nullif(t.attendee_name, ''), p.display_name),
           t.tier_name, t.barcode_secret, t.promoter_id, t.pending_transfer_id
    FROM public.exos_tickets t
    LEFT JOIN public.exos_profiles p ON p.id = t.owner_id
    WHERE t.event_id = p_event_id;
END $$;

REVOKE EXECUTE ON FUNCTION public.exos_event_checkin_roster(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_checkin_roster(uuid) TO authenticated, service_role;
