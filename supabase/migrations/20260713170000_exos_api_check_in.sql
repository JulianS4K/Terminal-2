-- ============================================================================
-- Migration 20260713170000 — Exos (Bridge / D4): programmatic check-in via the
--                            public REST API (exos-api edge fn).
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_event_checkins (W: scanned_by → nullable, source CHECK +'api',
--             +api_key_id col), NEW exos_api_check_in_ticket() RPC (service_role).
-- Pre-reqs: 20260520130000 (exos_event_checkins, exos_tickets),
--           20260702120000 (doors gate + checkin_test_mode),
--           20260713120000 (exos_checkin_idempotency + v2 barcode format),
--           20260616200000 (exos_api_keys — the caller's org comes from here).
--
-- The existing exos-api edge function is read-only. This adds the write path a
-- door-app integration needs — POST /events/:id/check-in — matching the check-in
-- capability hi.events exposes. The edge fn authenticates the Bearer API key
-- (SHA-256 vs exos_api_keys), resolves its org, then calls this RPC as
-- service_role. There is NO auth.uid() actor, so:
--
--   * scanned_by becomes NULLABLE and API check-ins record scanned_by = NULL +
--     api_key_id = <the key> for attribution (the FK was already ON DELETE SET
--     NULL, so NOT NULL was a latent contradiction — fixed here).
--   * source gains 'api'.
--   * org authority comes from the p_org the edge fn resolved from the key hash;
--     the RPC refuses a ticket whose org_id <> p_org (a key can only check in
--     its own org's tickets).
--   * A signed barcode is REQUIRED (v1 `T-` or v2 `T2-`); there is no manual
--     staff-override path over the API (no trusted human at the door). Bare /
--     legacy payloads are rejected exactly like a camera scan.
--   * Same atomic single-use flip + idempotency-key dedupe as the interactive
--     RPC, so a retried POST is a no-op.
--
-- The barcode-verification body mirrors exos_check_in_ticket (mig 20260713120000)
-- rather than sharing a helper — a deliberate, tested duplication kept simple;
-- if a third caller appears, extract exos_verify_barcode() then.
--
-- ⚠ New ticketing write path — B1 review before prod. D4 authors; validate on a
-- Supabase preview branch; A1 applies. NOT APPLIED by this change.
-- ============================================================================

-- 1. Audit-table shape for a non-human actor.
ALTER TABLE public.exos_event_checkins ALTER COLUMN scanned_by DROP NOT NULL;
ALTER TABLE public.exos_event_checkins DROP CONSTRAINT IF EXISTS exos_event_checkins_source_check;
ALTER TABLE public.exos_event_checkins
  ADD CONSTRAINT exos_event_checkins_source_check CHECK (source IN ('camera','manual','api'));
ALTER TABLE public.exos_event_checkins ADD COLUMN IF NOT EXISTS api_key_id uuid;

COMMENT ON COLUMN public.exos_event_checkins.api_key_id IS
  'D4 mig 20260713170000: the exos_api_keys row that performed an API check-in
   (source=''api''); NULL for human camera/manual scans.';

-- 2. Service-role, org-scoped, signed-barcode-required check-in.
CREATE OR REPLACE FUNCTION public.exos_api_check_in_ticket(
  p_org             uuid,
  p_ticket          uuid,
  p_barcode_payload text DEFAULT NULL,
  p_idempotency_key uuid DEFAULT NULL,
  p_api_key_id      uuid DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_org       uuid;
  v_event     uuid;
  v_prev      text;
  v_pending   uuid;
  v_owner     uuid;
  v_secret    text;
  v_updated   int;
  v_open_at   timestamptz;
  v_test_mode boolean := false;
  v_idem      jsonb;
BEGIN
  IF p_idempotency_key IS NOT NULL THEN
    SELECT result INTO v_idem FROM public.exos_checkin_idempotency
      WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN RETURN v_idem; END IF;
  END IF;

  SELECT org_id, event_id, status, pending_transfer_id, owner_id, barcode_secret
    INTO v_org, v_event, v_prev, v_pending, v_owner, v_secret
    FROM public.exos_tickets WHERE id = p_ticket;
  IF v_org IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  -- Org scoping: the API key can only check in tickets of its own org.
  IF v_org <> p_org THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-org');
  END IF;

  SELECT coalesce(e.doors_at, e.starts_at), coalesce(e.checkin_test_mode, false)
    INTO v_open_at, v_test_mode
    FROM public.exos_events e WHERE e.id = v_event;
  IF NOT v_test_mode AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'doors-not-open', 'opens_at', v_open_at);
  END IF;

  -- A signed barcode is REQUIRED over the API (no human override path).
  IF p_barcode_payload IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'barcode-required');
  END IF;

  DECLARE
    v_is_v2 boolean := left(p_barcode_payload, 3) = 'T2-';
    v_is_v1 boolean := left(p_barcode_payload, 3) <> 'T2-' AND left(p_barcode_payload, 2) = 'T-';
  BEGIN
    IF v_is_v2 THEN
      DECLARE
        v_tag text := substr(p_barcode_payload, 4, 1);
        v_b64 text; v_bytes bytea; v_total int; v_siglen int; v_msg bytea; v_sig bytea;
        v_cur bigint := floor(extract(epoch FROM now()) * 1000 / 30000);
        v_bkt bigint := 0; v_i int := 32; v_shift bigint := 1; v_byte int;
        v_pub bytea; v_ok boolean;
      BEGIN
        IF v_tag = 'h' THEN v_siglen := 16;
        ELSIF v_tag = 'e' THEN v_siglen := 64;
        ELSE RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        v_b64 := translate(substr(p_barcode_payload, 5), '-_', '+/');
        v_b64 := v_b64 || repeat('=', (4 - (length(v_b64) % 4)) % 4);
        v_bytes := decode(v_b64, 'base64');
        v_total := octet_length(v_bytes);
        IF v_total < 34 + v_siglen THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        v_msg := substring(v_bytes for v_total - v_siglen);
        v_sig := substring(v_bytes from v_total - v_siglen + 1);
        IF substring(v_msg for 16) <> decode(replace(p_ticket::text, '-', ''), 'hex')
           OR substring(v_msg from 17 for 16) <> decode(replace(coalesce(v_owner::text, ''), '-', ''), 'hex') THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        LOOP
          v_byte := get_byte(v_msg, v_i);
          v_bkt := v_bkt + (v_byte & 127) * v_shift;
          v_i := v_i + 1;
          EXIT WHEN (v_byte & 128) = 0;
          v_shift := v_shift * 128;
        END LOOP;
        IF abs(v_cur - v_bkt) > 2 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-expired');
        END IF;
        IF v_tag = 'h' THEN
          IF substring(extensions.hmac(v_msg, convert_to(coalesce(v_secret, ''), 'UTF8'), 'sha256') for 16) <> v_sig THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
          END IF;
        ELSE
          SELECT ed25519_public INTO v_pub FROM public.exos_org_barcode_keys WHERE org_id = v_org;
          IF v_pub IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected'); END IF;
          BEGIN
            v_ok := pgsodium.crypto_sign_verify_detached(v_sig, v_msg, v_pub);
          EXCEPTION WHEN others THEN v_ok := false;
          END;
          IF NOT coalesce(v_ok, false) THEN RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected'); END IF;
        END IF;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END;
    ELSIF v_is_v1 THEN
      DECLARE
        v_parts text[] := string_to_array(substring(p_barcode_payload FROM 3), ':');
        v_cur bigint := floor(extract(epoch FROM now()) * 1000 / 30000);
        v_bkt bigint; v_exp text;
      BEGIN
        IF array_length(v_parts, 1) <> 4 THEN RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected'); END IF;
        IF v_parts[1] <> p_ticket::text OR v_parts[2] <> v_owner::text THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        v_bkt := v_parts[3]::bigint;
        IF abs(v_cur - v_bkt) > 2 THEN RETURN jsonb_build_object('ok', false, 'reason', 'barcode-expired'); END IF;
        v_exp := rtrim(translate(encode(
                   extensions.hmac(v_parts[1] || ':' || v_parts[2] || ':' || v_parts[3],
                                   coalesce(v_secret, ''), 'sha256'), 'base64'), '+/', '-_'), '=');
        IF v_exp <> v_parts[4] THEN RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected'); END IF;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END;
    ELSE
      -- bare / legacy payload over the API → rejected (forgeable).
      RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
    END IF;
  END;

  IF v_pending IS NOT NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer'); END IF;
  IF v_prev = 'voided' THEN RETURN jsonb_build_object('ok', false, 'reason', 'voided'); END IF;
  IF v_prev = 'used' THEN
    IF p_idempotency_key IS NOT NULL THEN
      INSERT INTO public.exos_checkin_idempotency(idempotency_key, ticket_id, result)
      VALUES (p_idempotency_key, p_ticket, jsonb_build_object('ok', false, 'reason', 'used'))
      ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'used');
  END IF;

  UPDATE public.exos_tickets SET status = 'used', check_in_at = now()
   WHERE id = p_ticket AND status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'used'); END IF;

  INSERT INTO public.exos_event_checkins
    (event_id, ticket_id, org_id, scanned_by, scanned_by_email, source, verification, api_key_id)
  VALUES (v_event, p_ticket, v_org, NULL, NULL, 'api', 'verified', p_api_key_id);

  IF p_idempotency_key IS NOT NULL THEN
    INSERT INTO public.exos_checkin_idempotency(idempotency_key, ticket_id, result)
    VALUES (p_idempotency_key, p_ticket, jsonb_build_object('ok', true, 'reason', 'checked-in'))
    ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in');
END $function$;

-- service_role only: the edge fn calls this after authenticating the API key.
-- No anon/authenticated grant — humans use exos_check_in_ticket.
REVOKE ALL ON FUNCTION public.exos_api_check_in_ticket(uuid, uuid, text, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_api_check_in_ticket(uuid, uuid, text, uuid, uuid) TO service_role;

-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.exos_api_check_in_ticket(uuid, uuid, text, uuid, uuid);
--   ALTER TABLE public.exos_event_checkins DROP COLUMN IF EXISTS api_key_id;
--   ALTER TABLE public.exos_event_checkins DROP CONSTRAINT IF EXISTS exos_event_checkins_source_check;
--   ALTER TABLE public.exos_event_checkins ADD CONSTRAINT exos_event_checkins_source_check CHECK (source IN ('camera','manual'));
--   -- (scanned_by NOT NULL not restored — nullable is the correct shape.)
