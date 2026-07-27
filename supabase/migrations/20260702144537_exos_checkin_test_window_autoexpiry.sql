-- ============================================================================
-- Migration 20260702144537 — Exos (Bridge / D4): doors-gate test-mode auto-expiry
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  ALTER exos_events (+checkin_test_until), REPLACE exos_check_in_ticket,
--           NEW exos_set_checkin_test_window RPC
-- Pre-reqs: 20260702120000 (doors gate + checkin_test_mode)
--
-- HARDENING (audit follow-up 2026-07-02). The doors gate added in 20260702120000
-- is bypassed by a plain boolean `checkin_test_mode`. Left on, it silently
-- disables the gate for a real event, so tickets can be scanned/used before
-- doors. Fix: test mode now AUTO-EXPIRES — the gate only honors it while
-- `checkin_test_until > now()`, and the bare boolean alone has no effect. An
-- owner/manager enables a bounded window (e.g. "test scanning for 3h") via the
-- new exos_set_checkin_test_window RPC; it lapses on its own. This keeps the
-- emergency override available for a real event with a mis-set doors_at without
-- the left-on-forever footgun.
--
-- exos_check_in_ticket body is identical to 20260702120000 except the test-mode
-- predicate. D4 authors; A1 applies to prod.
-- ============================================================================

ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS checkin_test_until timestamptz;

COMMENT ON COLUMN public.exos_events.checkin_test_until IS
  'D4 mig 20260702144537: doors-gate test mode is honored only while now() <
   checkin_test_until (auto-expiry). Set together with checkin_test_mode via
   exos_set_checkin_test_window. NULL/past = gate enforced.';

-- Owner/manager enables a BOUNDED test-scanning window (or clears it with
-- p_hours <= 0). Server-authoritative; not a client-writable free-for-all.
CREATE OR REPLACE FUNCTION public.exos_set_checkin_test_window(
  p_event_id uuid,
  p_hours    numeric DEFAULT 3
)
 RETURNS timestamptz
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_org   uuid;
  v_until timestamptz;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_set_checkin_test_window: event not found';
  END IF;
  IF auth.uid() IS NULL OR NOT exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_set_checkin_test_window: not authorized' USING ERRCODE = '42501';
  END IF;

  IF coalesce(p_hours, 0) <= 0 THEN
    UPDATE public.exos_events
       SET checkin_test_mode = false, checkin_test_until = NULL
     WHERE id = p_event_id;
    RETURN NULL;
  END IF;

  -- Cap the window at 24h so a fat-fingered value can't re-create the
  -- left-on-forever risk.
  v_until := now() + (least(p_hours, 24) * interval '1 hour');
  UPDATE public.exos_events
     SET checkin_test_mode = true, checkin_test_until = v_until
   WHERE id = p_event_id;
  RETURN v_until;
END $function$;
REVOKE ALL ON FUNCTION public.exos_set_checkin_test_window(uuid, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_checkin_test_window(uuid, numeric) TO authenticated;

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
  v_test      boolean := false;
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

  IF p_event_id IS NOT NULL AND v_event <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;

  -- Doors-open gate. Test mode is honored ONLY while checkin_test_until is in
  -- the future (auto-expiry — the bare boolean alone can't disable the gate).
  SELECT coalesce(e.doors_at, e.starts_at),
         (coalesce(e.checkin_test_mode, false)
           AND e.checkin_test_until IS NOT NULL
           AND now() < e.checkin_test_until)
    INTO v_open_at, v_test
    FROM public.exos_events e WHERE e.id = v_event;
  IF NOT v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'doors-not-open',
                              'opens_at', v_open_at);
  END IF;

  -- Barcode verification (unchanged from 20260702120000): a camera scan MUST
  -- present a valid 4-segment signed barcode; manual typed entry is a staff
  -- override; legacy/bare payloads are rejected.
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
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    END IF;
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
    RETURN jsonb_build_object('ok', false, 'reason', 'used');
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

-- ROLLBACK: recreate exos_check_in_ticket from mig 20260702120000 (bare-boolean
-- test mode), drop exos_set_checkin_test_window, DROP COLUMN checkin_test_until.
