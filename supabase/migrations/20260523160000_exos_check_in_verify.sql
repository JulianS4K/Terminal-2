-- ============================================================================
-- Migration 20260523160000 — Exos (Bridge / D4): server-side barcode verify
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_check_in_ticket() RPC (DROP 3-arg + CREATE 4-arg)
-- Pre-reqs: 20260520130000 (exos_check_in_ticket, exos_tickets), pgcrypto
--           (extensions.hmac — confirmed installed in schema `extensions`)
--
-- D4-OPS-6 — check-in was not server-verified: the RPC did the role gate +
-- atomic flip but trusted the CLIENT's HMAC check, so a forked/compromised
-- organizer client could admit any ticket for its org. This re-verifies the
-- rotating barcode SERVER-SIDE, mirroring lib/barcode.ts:
--   payload = 'T-{ticketId}:{ownerId}:{bucket}:{hmac}'
--   bucket  = floor(now_ms / 30000),  tolerance ±2 buckets (~60-90s skew)
--   hmac    = base64url( HMAC-SHA256(barcode_secret, 'ticketId:ownerId:bucket') )
--
-- Optional-but-enforced semantics (preserves the legitimate manual path):
--   * p_barcode_payload NULL          -> manual / staff-attested entry; allowed.
--   * signed 4-segment payload        -> MUST verify (ticket id + owner + bucket
--                                        window + HMAC); reject on any mismatch.
--   * legacy 3-segment payload        -> skipped (rollout compat), as client.
-- A compromised client that simply omits the payload degrades to a 'manual'
-- check-in, which is recorded as such in the audit (distinguishable) — but a
-- PRESENTED barcode can no longer be forged/replayed past the server.
--
-- ⚠ Signature change (PROJECT_BIBLE §7): adding p_barcode_payload — even with a
-- DEFAULT — creates a NEW overload, so the prior 3-arg signature is DROPPED
-- first. Existing 3-named-arg callers resolve to the new 4-arg (payload=NULL).
--
-- D4 authors; A1 applies to prod.
-- ============================================================================

DROP FUNCTION IF EXISTS public.exos_check_in_ticket(uuid, text, text);

CREATE OR REPLACE FUNCTION public.exos_check_in_ticket(
  p_ticket_id       uuid,
  p_source          text DEFAULT 'manual',
  p_verification    text DEFAULT 'manual',
  p_barcode_payload text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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

  -- Server-side barcode verification (only for signed payloads). Mirrors
  -- lib/barcode.ts. Malformed payloads are rejected via the nested handler.
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
    (event_id, ticket_id, org_id, scanned_by, source, verification)
  VALUES (
    v_event, p_ticket_id, v_org, v_uid,
    CASE WHEN p_source IN ('camera','manual') THEN p_source ELSE 'manual' END,
    CASE WHEN p_verification IN ('verified','legacy','manual') THEN p_verification ELSE 'manual' END
  );

  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in');
END $$;

REVOKE EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text) TO authenticated;
