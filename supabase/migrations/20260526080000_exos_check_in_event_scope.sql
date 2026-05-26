-- 20260526080000_exos_check_in_event_scope.sql
--
-- D4-OPS-18: server-side event scoping for check-in + populate scanned_by_email.
--
-- Today exos_check_in_ticket is org-scoped (any owner/manager/scanner of the
-- ticket's org can flip it); the "is this ticket for THIS door's event?" check
-- lives only in the FE (OrganizerCheckIn compares scanTicket.eventId). At a
-- multi-event org, a valid ticket for event A could be flipped at event B's
-- door if the client check were bypassed. Add an optional p_event_id and, when
-- supplied, reject a cross-event scan server-side (reason 'wrong-event').
--
-- Also denormalizes the scanner's email onto the audit row (mig 20260526070000).
--
-- Backward compatible: p_event_id defaults NULL → behaviour unchanged. The FE
-- passes the door's eventId, so they must ship together (apply this migration
-- with the keyed static/bridge rebuild). The old 4-arg overload is dropped to
-- avoid `function is not unique` ambiguity (§7 signature-change landmine).
--
-- D4 authors; A1 applies (B1 review: door-security surface).
-- ─────────────────────────────────────────────────────────────────────────────

-- Drop the prior 4-arg signature before adding the p_event_id overload.
DROP FUNCTION IF EXISTS public.exos_check_in_ticket(uuid, text, text, text);

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
  v_uid     uuid := auth.uid();
  v_org     uuid;
  v_event   uuid;
  v_prev    text;
  v_pending uuid;
  v_owner   uuid;
  v_secret  text;
  v_updated int;
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

  -- Server-side barcode verification (only for signed payloads).
  IF p_barcode_payload IS NOT NULL AND left(p_barcode_payload, 2) = 'T-' THEN
    DECLARE
      v_parts text[] := string_to_array(substring(p_barcode_payload FROM 3), ':');
      v_cur   bigint := floor(extract(epoch FROM now()) * 1000 / 30000);
      v_bkt   bigint;
      v_exp   text;
    BEGIN
      IF array_length(v_parts, 1) = 4 THEN     -- signed; 3 = legacy (skip)
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
      ELSIF array_length(v_parts, 1) <> 3 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END IF;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    END;
  END IF;

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

-- ROLLBACK: drop the 5-arg fn and recreate the 4-arg version from
-- mig 20260523160000 (and DROP COLUMN scanned_by_email if rolling back 070000).
