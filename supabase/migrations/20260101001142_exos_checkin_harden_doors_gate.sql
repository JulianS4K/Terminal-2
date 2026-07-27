-- ============================================================================
-- Migration 20260702120000 — Exos (Bridge / D4): check-in hardening + doors gate
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  ALTER exos_events (+checkin_test_mode), REPLACE exos_check_in_ticket
-- Pre-reqs: 20260520120000 (events), 20260605132000 (5-arg check-in RPC)
--
-- SECURITY FIX (audit 2026-07-02, HIGH). Two holes in door check-in:
--
--   1. Barcode downgrade. exos_check_in_ticket only ran the HMAC/owner/bucket
--      check when the payload had 4 segments; a 3-segment "legacy" payload
--      (T-{ticketId}:{ownerId}:{bucket}) and a bare ticket UUID fell straight
--      through to the atomic status flip with NO verification. Since the ticket
--      UUID is rendered in plaintext on the pass, anyone who photographs a QR
--      could forge an accepted code and walk in on someone else's ticket. We now
--      REJECT any T- payload that is not a valid 4-segment signed barcode, and
--      REQUIRE a valid signed barcode for camera scans (source='camera'). Manual
--      typed entry by authorized staff (source='manual') stays an explicit,
--      audited override — the staff RLS read is the gate there.
--
--   2. No doors gate. Check-in was accepted at any time. Per operator directive,
--      a ticket must not be scanned/checked in BEFORE the event's doors time,
--      except when the organizer has explicitly enabled a server-authoritative
--      test mode on the event (exos_events.checkin_test_mode). The flag is
--      owner/manager-settable via the existing exos_events_upd RLS policy; it is
--      NOT a client-supplied argument (an attacker can't set it).
--
-- Signature unchanged (5-arg) so the FE contract and grants carry over.
-- D4 authors; A1 applies to prod.
-- ============================================================================

-- Server-authoritative "testing" flag. Default false = doors gate enforced.
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS checkin_test_mode boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.exos_events.checkin_test_mode IS
  'D4 mig 20260702120000: when true, exos_check_in_ticket skips the doors-open
   gate for this event (organizer scanner testing). Owner/manager-settable via
   exos_events_upd RLS. MUST be disabled before real doors — leaving it on lets
   staff check attendees in before doors_at.';

CREATE OR REPLACE FUNCTION public.exos_check_in_ticket(
  p_ticket_id       uuid,
  p_source          text DEFAULT 'manual',
  p_verification    text DEFAULT 'manual',
  p_barcode_payload text DEFAULT NULL,
  p_event_id        uuid DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_org       uuid;
  v_event     uuid;
  v_prev      text;
  v_pending   uuid;
  v_owner     uuid;
  v_secret    text;
  v_updated   int;
  v_open_at   timestamptz;
  v_test_mode boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT org_id, event_id, status, pending_transfer_id, owner_id, barcode_secret
    INTO v_org, v_event, v_prev, v_pending, v_owner, v_secret
    FROM public.exos_tickets WHERE id = p_ticket_id;
  IF v_org IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;

  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authorized' USING ERRCODE = '42501';
  END IF;

  -- Event scoping (D4-OPS-18). When the caller passes the door's event id,
  -- reject a ticket that belongs to a different event of the same org.
  IF p_event_id IS NOT NULL AND v_event <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;

  -- Doors-open gate (2026-07-02). Refuse check-in before the event's doors
  -- time (fall back to starts_at) unless the organizer enabled test mode.
  SELECT coalesce(e.doors_at, e.starts_at), coalesce(e.checkin_test_mode, false)
    INTO v_open_at, v_test_mode
    FROM public.exos_events e WHERE e.id = v_event;
  IF NOT v_test_mode AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'doors-not-open',
                              'opens_at', v_open_at);
  END IF;

  -- Barcode verification. A camera scan MUST present a valid 4-segment signed
  -- barcode; a bare UUID or 3-segment "legacy" payload is NO LONGER accepted
  -- (that was the forgery downgrade). Manual typed entry (source='manual') with
  -- no signed payload is an authorized-staff override, gated by staff RLS.
  DECLARE
    v_signed boolean := (p_barcode_payload IS NOT NULL AND left(p_barcode_payload, 2) = 'T-');
  BEGIN
    IF v_signed THEN
      DECLARE
        v_parts text[] := string_to_array(substring(p_barcode_payload FROM 3), ':');
        v_cur   bigint := floor(extract(epoch FROM now()) * 1000 / 30000);
        v_bkt   bigint;
        v_exp   text;
      BEGIN
        IF array_length(v_parts, 1) <> 4 THEN
          -- Unsigned / legacy 3-segment payloads are rejected outright.
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        IF v_parts[1] <> p_ticket_id::text OR v_parts[2] <> v_owner::text THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        v_bkt := v_parts[3]::bigint;
        IF abs(v_cur - v_bkt) > 2 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-expired');
        END IF;
        v_exp := rtrim(translate(encode(
                   extensions.hmac(v_parts[1] || ':' || v_parts[2] || ':' || v_parts[3],
                                   coalesce(v_secret, ''), 'sha256'), 'base64'),
                   '+/', '-_'), '=');
        IF v_exp <> v_parts[4] THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END;
    ELSIF p_source = 'camera' THEN
      -- A scanned code that is not a signed barcode (bare id or forged legacy
      -- QR) is refused: the camera path can only admit a valid signed barcode.
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    END IF;
    -- else: manual typed entry with no signed payload → authorized-staff override.
  END;

  IF v_pending IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer');
  END IF;
  IF v_prev = 'voided' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'voided');
  END IF;
  IF v_prev = 'used' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'used');
  END IF;

  UPDATE public.exos_tickets
     SET status = 'used', check_in_at = now()
   WHERE id = p_ticket_id AND status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'used');  -- lost the race
  END IF;

  INSERT INTO public.exos_event_checkins
    (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification)
  VALUES (
    v_event, p_ticket_id, v_org, v_uid,
    lower(coalesce(auth.jwt() ->> 'email', '')),
    CASE WHEN p_source IN ('camera','manual') THEN p_source ELSE 'manual' END,
    CASE WHEN p_verification IN ('verified','legacy','manual') THEN p_verification ELSE 'manual' END
  );

  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in');
END $function$;

REVOKE ALL ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text, uuid) TO authenticated;

-- ROLLBACK: recreate the body from mig 20260605132000 (restores the legacy
-- fall-through + no doors gate) and DROP COLUMN exos_events.checkin_test_mode.
