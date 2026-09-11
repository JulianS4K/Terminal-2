-- ============================================================================
-- Migration 20260713120000 — Exos (Bridge / D4): Ed25519 barcodes, idempotent
--                            check-in (server-crash safety), signed offline
--                            revocation manifest.
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  NEW exos_org_barcode_keys (org Ed25519 keypair; private = secret),
--           NEW exos_org_barcode_pubkey(uuid) RPC (public key for scanners),
--           NEW exos_checkin_idempotency (replay-dedupe for crash safety),
--           REPLACE exos_check_in_ticket (DROP 5-arg + CREATE 6-arg: adds
--             p_idempotency_key + v2/Ed25519 barcode verification),
--           NEW exos_event_revocation_manifest(uuid) RPC (signed used/void set).
-- Pre-reqs: 20260702120000 (5-arg exos_check_in_ticket + doors gate +
--           checkin_test_mode), 20260520130000 (exos_tickets, exos_has_org_role,
--           exos_is_admin), extensions.hmac (pgcrypto). Ed25519 verify/sign use
--           the `pgsodium` extension — see the ⚠ note below.
--
-- WHY (pushing the QR/scanner limits, three axes; see d4_bridge/src/lib/*):
--
--   1. Offline verification WITHOUT a shared secret (Ed25519). Today's HMAC is
--      symmetric, so an offline door must hold each ticket's barcode_secret (the
--      exos_ticket_barcode_secrets registry) — a stolen scanner can then FORGE
--      codes. The new `ed25519` barcode scheme signs with the org PRIVATE key
--      (stored here, service-role-only) and is verified with the org PUBLIC key
--      (exposed via exos_org_barcode_pubkey). A leaked scanner can verify but
--      never forge. This is the airline/SafeTix-grade offline model.
--
--   2. Server-crash safety (idempotent check-in). A crash between the atomic
--      status flip and the client dropping its offline replay queue currently
--      lets the reconnect replay write a SECOND exos_event_checkins audit row
--      (head-count inflation). p_idempotency_key makes a replay return the first
--      result verbatim, writing no second row.
--
--   3. Smaller/faster symbol (v2 binary). v2 packs the two UUIDs to raw bytes +
--      a varint bucket + a compact signature (`T2-{h|e}{base64url}`), roughly
--      halving the module count of the HMAC scheme vs the v1 text format — a
--      faster lock under bad door lighting, still a plain QR any phone reads.
--
-- The v1 (`T-…`) HMAC path is REPRODUCED UNCHANGED below; v2 is additive and is
-- gated OFF in the frontend (VITE_BARCODE_V2) until this migration is validated.
--
-- ⚠ pgsodium dependency + canonical-encoding validation. Ed25519 sign/verify and
--   the manifest signature use `pgsodium`. The v2 `hmac` scheme needs only
--   pgcrypto and works without it; the `ed25519` scheme and manifest signing are
--   INERT (verify → reject; manifest signature → null → client re-checks online,
--   fail-closed) until pgsodium is enabled. The manifest's canonical JSON must be
--   byte-identical to canonicalManifestBytes() in offlineManifest.ts — VALIDATE
--   ON A SUPABASE PREVIEW BRANCH before enabling ed25519 issuance.
--
-- ⚠ B1 review requested on the privilege + crypto model before prod apply.
--   D4 authors; validate on a Supabase preview branch; A1 applies. NOT APPLIED
--   to prod by this change — file authored only (operator lockdown Rule 1).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Per-org Ed25519 keypair. The PRIVATE key is a secret: readable only by the
--    table owner / service_role and the SECURITY DEFINER functions below — never
--    by anon/authenticated. The PUBLIC key is not secret and is handed to
--    scanners via exos_org_barcode_pubkey(). No FK on org_id (kept soft so this
--    is decoupled from the exos_orgs surface); org_id is the PK.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_org_barcode_keys (
  org_id          uuid PRIMARY KEY,
  ed25519_public  bytea NOT NULL,           -- raw 32-byte public key
  ed25519_private bytea NOT NULL,           -- pgsodium 64-byte secret key
  created_at      timestamptz NOT NULL DEFAULT now(),
  rotated_at      timestamptz
);
COMMENT ON TABLE public.exos_org_barcode_keys IS
  'D4 mig 20260713120000: per-org Ed25519 keypair for asymmetric (no-secret-on-
   scanner) barcodes + signed offline revocation manifests. ed25519_private is a
   secret — never grant to anon/authenticated.';

-- Lock the table down: no client (anon or authenticated) reads it directly. Only
-- the SECURITY DEFINER RPCs (running as owner) and service_role touch it.
REVOKE ALL ON public.exos_org_barcode_keys FROM anon, authenticated;
ALTER TABLE public.exos_org_barcode_keys ENABLE ROW LEVEL SECURITY;
-- (No permissive policy = no row is visible to anon/authenticated even if a
--  table grant were ever mistakenly added. Defense in depth for the secret.)

-- Public key read surface for scanners. Public keys are not secret.
CREATE OR REPLACE FUNCTION public.exos_org_barcode_pubkey(p_org uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT rtrim(translate(encode(ed25519_public, 'base64'), '+/', '-_'), '=')
  FROM public.exos_org_barcode_keys
  WHERE org_id = p_org;
$$;
REVOKE EXECUTE ON FUNCTION public.exos_org_barcode_pubkey(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_org_barcode_pubkey(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Idempotency ledger for crash-safe replay. Keyed by a client-generated
--    per-admit uuid; stores the result so a replay returns it verbatim without
--    a second audit row. Client-inaccessible (SECURITY DEFINER writes only).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_checkin_idempotency (
  idempotency_key uuid PRIMARY KEY,
  ticket_id       uuid NOT NULL,
  result          jsonb NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON public.exos_checkin_idempotency FROM anon, authenticated;
ALTER TABLE public.exos_checkin_idempotency ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 3. exos_check_in_ticket — add p_idempotency_key + v2/Ed25519 verification.
--    Adding an argument (even DEFAULT) makes a NEW overload, so DROP the 5-arg
--    first (PROJECT_BIBLE §7). The v1 body from mig 20260702120000 is preserved
--    byte-for-byte; the only additions are (a) the idempotency short-circuit +
--    store, and (b) the v2 (`T2-`) branch in barcode verification.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.exos_check_in_ticket(uuid, text, text, text, uuid);

CREATE OR REPLACE FUNCTION public.exos_check_in_ticket(
  p_ticket_id       uuid,
  p_source          text DEFAULT 'manual',
  p_verification    text DEFAULT 'manual',
  p_barcode_payload text DEFAULT NULL,
  p_event_id        uuid DEFAULT NULL,
  p_idempotency_key uuid DEFAULT NULL
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
  v_idem      jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Crash-safe replay: a retried check-in (same idempotency key) returns the
  -- stored result and writes NO second audit row.
  IF p_idempotency_key IS NOT NULL THEN
    SELECT result INTO v_idem FROM public.exos_checkin_idempotency
      WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN RETURN v_idem; END IF;
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

  SELECT coalesce(e.doors_at, e.starts_at), coalesce(e.checkin_test_mode, false)
    INTO v_open_at, v_test_mode
    FROM public.exos_events e WHERE e.id = v_event;
  IF NOT v_test_mode AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'doors-not-open',
                              'opens_at', v_open_at);
  END IF;

  -- Barcode verification. v2 (`T2-`) and v1 (`T-`) signed barcodes are both
  -- re-verified server-side; a bare/legacy code on the camera path is rejected.
  DECLARE
    v_is_v2 boolean := (p_barcode_payload IS NOT NULL AND left(p_barcode_payload, 3) = 'T2-');
    v_is_v1 boolean := (p_barcode_payload IS NOT NULL AND left(p_barcode_payload, 3) <> 'T2-'
                        AND left(p_barcode_payload, 2) = 'T-');
  BEGIN
    IF v_is_v2 THEN
      -- v2 binary: `T2-{tag}{base64url(ticket16||owner16||varint(bucket)||sig)}`
      DECLARE
        v_tag    text  := substr(p_barcode_payload, 4, 1);
        v_b64    text;
        v_bytes  bytea;
        v_total  int;
        v_siglen int;
        v_msg    bytea;
        v_sig    bytea;
        v_cur    bigint := floor(extract(epoch FROM now()) * 1000 / 30000);
        v_bkt    bigint := 0;
        v_i      int := 32;         -- 0-indexed byte offset of the bucket varint
        v_shift  bigint := 1;
        v_byte   int;
        v_pub    bytea;
        v_ok     boolean;
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

        -- Bind to THIS ticket + its current owner.
        IF substring(v_msg for 16) <> decode(replace(p_ticket_id::text, '-', ''), 'hex')
           OR substring(v_msg from 17 for 16) <> decode(replace(coalesce(v_owner::text, ''), '-', ''), 'hex') THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;

        -- Parse the LEB128 bucket varint (get_byte is 0-indexed).
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
          -- Truncated (128-bit) HMAC-SHA256 over the message bytes.
          IF substring(extensions.hmac(v_msg, convert_to(coalesce(v_secret, ''), 'UTF8'), 'sha256')
                       for 16) <> v_sig THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
          END IF;
        ELSE
          -- Ed25519 verify with the org PUBLIC key. Requires pgsodium; if it is
          -- unavailable the scheme cannot be server-verified and is rejected
          -- (enable pgsodium before turning on ed25519 issuance).
          SELECT ed25519_public INTO v_pub FROM public.exos_org_barcode_keys WHERE org_id = v_org;
          IF v_pub IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
          END IF;
          BEGIN
            v_ok := pgsodium.crypto_sign_verify_detached(v_sig, v_msg, v_pub);
          EXCEPTION WHEN others THEN
            v_ok := false;
          END;
          IF NOT coalesce(v_ok, false) THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
          END IF;
        END IF;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
      END;

    ELSIF v_is_v1 THEN
      -- v1 text: `T-{ticketId}:{ownerId}:{bucket}:{hmac}` (unchanged).
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
    -- else: manual typed entry with no signed payload → authorized-staff override.
  END;

  IF v_pending IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer');
  END IF;
  IF v_prev = 'voided' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'voided');
  END IF;
  IF v_prev = 'used' THEN
    -- Idempotent replays of an already-used ticket record the same stable result
    -- so the client queue drops them instead of retrying forever.
    IF p_idempotency_key IS NOT NULL THEN
      INSERT INTO public.exos_checkin_idempotency(idempotency_key, ticket_id, result)
      VALUES (p_idempotency_key, p_ticket_id, jsonb_build_object('ok', false, 'reason', 'used'))
      ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;
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

  -- Record the committed result so a crash-then-replay is a no-op.
  IF p_idempotency_key IS NOT NULL THEN
    INSERT INTO public.exos_checkin_idempotency(idempotency_key, ticket_id, result)
    VALUES (p_idempotency_key, p_ticket_id, jsonb_build_object('ok', true, 'reason', 'checked-in'))
    ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in');
END $function$;

REVOKE ALL ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text, text, uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Signed offline revocation manifest. Returns the used/voided ticket-id set
--    for an event as of now, Ed25519-signed with the org key so an offline
--    scanner can reject an already-burned ticket with zero network and no
--    forgeable trust. Signature is null when pgsodium is unavailable — the
--    client then re-checks online (fail-closed, never admits on a bad manifest).
--    ⚠ The canonical JSON here MUST match canonicalManifestBytes() byte-for-byte
--    (keys eventId, issuedAt, revoked-sorted). Validate on a preview branch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_revocation_manifest(p_event uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_issued bigint := floor(extract(epoch FROM now()) * 1000);
  v_ids    text[];
  v_canon  text;
  v_priv   bytea;
  v_sig    text := NULL;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event;
  IF v_org IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_event_revocation_manifest: not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(array_agg(id::text ORDER BY id::text), ARRAY[]::text[])
    INTO v_ids
    FROM public.exos_tickets
   WHERE event_id = p_event AND status IN ('used', 'voided');

  -- Must mirror JSON.stringify({eventId, issuedAt, revoked:[...sorted]}).
  v_canon := json_build_object('eventId', p_event::text, 'issuedAt', v_issued,
                               'revoked', to_jsonb(v_ids))::text;
  BEGIN
    SELECT ed25519_private INTO v_priv FROM public.exos_org_barcode_keys WHERE org_id = v_org;
    IF v_priv IS NOT NULL THEN
      v_sig := rtrim(translate(encode(
                 pgsodium.crypto_sign_detached(convert_to(v_canon, 'UTF8'), v_priv),
                 'base64'), '+/', '-_'), '=');
    END IF;
  EXCEPTION WHEN others THEN
    v_sig := NULL;
  END;

  RETURN jsonb_build_object(
    'manifest', jsonb_build_object('eventId', p_event::text, 'issuedAt', v_issued,
                                   'revoked', to_jsonb(v_ids)),
    'signature', v_sig
  );
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_event_revocation_manifest(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_revocation_manifest(uuid) TO authenticated, service_role;

-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.exos_event_revocation_manifest(uuid);
--   DROP FUNCTION IF EXISTS public.exos_check_in_ticket(uuid, text, text, text, uuid, uuid);
--   -- then recreate the 5-arg exos_check_in_ticket from mig 20260702120000
--   DROP FUNCTION IF EXISTS public.exos_org_barcode_pubkey(uuid);
--   DROP TABLE IF EXISTS public.exos_checkin_idempotency;
--   DROP TABLE IF EXISTS public.exos_org_barcode_keys;
