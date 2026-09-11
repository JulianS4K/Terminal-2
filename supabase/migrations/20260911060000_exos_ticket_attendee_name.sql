-- ============================================================================
-- Migration 20260911060000 — Exos (Bridge / D4): attendee name on tickets
--
-- Lane:     d4 (exos / bridge ticketing — customer-facing session)
-- Touches:  exos_tickets (W: +attendee_name, CHECK, trigger exos_tickets_attendee_reset),
--           exos_set_ticket_attendee(uuid, text) (new, holder RPC),
--           exos_tg_ticket_attendee_reset() (new, trigger fn)
-- Pre-reqs: 20260520130000 (exos_tickets), 20260702121000 (claim_transfer reassigns owner_id)
--
-- KANBAN D4-OPS-23 (attendee info capture), attendee half. A buyer who claims
-- several tickets hands them to friends; the door and the pass should show WHO
-- the ticket is for, not just who bought it. Adds a per-ticket display name the
-- CURRENT OWNER can set/clear while the ticket is active and not in transfer.
--
--   * Holder-only write, via RPC (exos_tickets has no client UPDATE policy —
--     keep it that way). Whitespace-collapsed, 1..80 chars, empty clears.
--   * Ownership change clears it: the new owner is the attendee. BEFORE UPDATE
--     OF owner_id trigger, so exos_claim_transfer needs no edit.
--   * Read surface: the column rides the existing owner/buyer/staff SELECT
--     policy — organizer roster/scanner/CSV (organizer session) can coalesce
--     attendee_name over the profile display name.
--
-- ROLLBACK: DROP TRIGGER exos_tickets_attendee_reset ON exos_tickets;
--   DROP FUNCTION exos_tg_ticket_attendee_reset(), exos_set_ticket_attendee(uuid,text);
--   ALTER TABLE exos_tickets DROP COLUMN attendee_name;
-- ============================================================================

ALTER TABLE public.exos_tickets ADD COLUMN IF NOT EXISTS attendee_name text;
ALTER TABLE public.exos_tickets DROP CONSTRAINT IF EXISTS exos_tickets_attendee_name_len;
ALTER TABLE public.exos_tickets ADD CONSTRAINT exos_tickets_attendee_name_len
  CHECK (attendee_name IS NULL OR char_length(attendee_name) BETWEEN 1 AND 80);
COMMENT ON COLUMN public.exos_tickets.attendee_name IS
  'Display name of the person this ticket is FOR (set by the current owner via exos_set_ticket_attendee; cleared automatically when owner_id changes). NULL = show the owner profile name.';

CREATE OR REPLACE FUNCTION public.exos_set_ticket_attendee(p_ticket_id uuid, p_name text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_owner   uuid;
  v_status  text;
  v_pending uuid;
  v_name    text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_set_ticket_attendee: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT owner_id, status, pending_transfer_id INTO v_owner, v_status, v_pending
    FROM public.exos_tickets WHERE id = p_ticket_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'exos_set_ticket_attendee: ticket not found';
  END IF;
  IF v_owner <> auth.uid() THEN
    RAISE EXCEPTION 'exos_set_ticket_attendee: not the ticket owner' USING ERRCODE = '42501';
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'exos_set_ticket_attendee: ticket is %', v_status;
  END IF;
  IF v_pending IS NOT NULL THEN
    RAISE EXCEPTION 'exos_set_ticket_attendee: ticket is in transfer';
  END IF;
  v_name := nullif(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), '');
  IF v_name IS NOT NULL AND char_length(v_name) > 80 THEN
    RAISE EXCEPTION 'exos_set_ticket_attendee: name too long (max 80)';
  END IF;
  UPDATE public.exos_tickets SET attendee_name = v_name WHERE id = p_ticket_id;
  RETURN v_name;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_set_ticket_attendee(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_ticket_attendee(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_tg_ticket_attendee_reset()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    NEW.attendee_name := NULL;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS exos_tickets_attendee_reset ON public.exos_tickets;
CREATE TRIGGER exos_tickets_attendee_reset
  BEFORE UPDATE OF owner_id ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_attendee_reset();
