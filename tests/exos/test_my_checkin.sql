-- ============================================================================
-- Extended check-in regression for migration 20260713120000 (Ed25519 + v2
-- binary barcodes + idempotent check-in). Runs AFTER the lifecycle chain + my
-- migration are applied (see run_my_migrations.sh), driving the REAL 6-arg
-- exos_check_in_ticket body:
--   * v2 `T2-h` binary HMAC scan is accepted,
--   * expired bucket + tampered signature are rejected,
--   * an idempotency key makes a replay a no-op (same result, one audit row).
-- Self-seeded (distinct cccc… uuids) so it doesn't collide with the lifecycle
-- test's data in the same DB. ASSERT-guarded; ON_ERROR_STOP aborts on failure.
-- ============================================================================

-- Build a v2 `T2-h` payload the exact inverse of the migration's verifier:
--   bytes = ticket16 || owner16 || leb128(bucket) || hmac16
CREATE FUNCTION pg_temp.leb128(n bigint) RETURNS bytea LANGUAGE plpgsql AS $$
DECLARE b bytea := ''; v bigint := n; byte int;
BEGIN
  LOOP
    byte := (v % 128)::int;
    v := v / 128;
    IF v > 0 THEN byte := byte + 128; END IF;
    b := b || set_byte('\x00'::bytea, 0, byte);
    EXIT WHEN v = 0;
  END LOOP;
  RETURN b;
END $$;

CREATE FUNCTION pg_temp.v2payload(tid uuid, oid uuid, secret text, bucket bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE msg bytea; sig bytea;
BEGIN
  msg := decode(replace(tid::text,'-',''),'hex')
      || decode(replace(oid::text,'-',''),'hex')
      || pg_temp.leb128(bucket);
  sig := substring(extensions.hmac(msg, convert_to(coalesce(secret,''),'UTF8'), 'sha256') for 16);
  RETURN 'T2-h' || rtrim(translate(encode(msg || sig, 'base64'), '+/', '-_'), '=');
END $$;

-- ── seed: scanner org + published event (doors already open) + tickets ──────
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('cccccccc-1111-1111-1111-111111111111','cscanner@x', now()),
  ('cccccccc-2222-2222-2222-222222222222','cbuyer@x',   now());
INSERT INTO public.exos_profiles (id, display_name) VALUES
  ('cccccccc-1111-1111-1111-111111111111','Casey Scanner'),
  ('cccccccc-2222-2222-2222-222222222222','Cam Buyer');
INSERT INTO public.exos_orgs (id, name, slug, owner_uid)
  VALUES ('cccccccc-0000-0000-0000-000000000001','V2 Org','v2-org',
          'cccccccc-1111-1111-1111-111111111111');
INSERT INTO public.exos_org_memberships (org_id, user_id, role)
  VALUES ('cccccccc-0000-0000-0000-000000000001','cccccccc-1111-1111-1111-111111111111','owner');
INSERT INTO public.exos_events (id, org_id, name, status, doors_at, starts_at, created_by, currency)
  VALUES ('cccccccc-0000-0000-0000-000000000002','cccccccc-0000-0000-0000-000000000001',
          'V2 Show','published', now() - interval '1 hour', now() + interval '2 hours',
          'cccccccc-1111-1111-1111-111111111111','USD');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, ticket_type, visibility)
  VALUES ('cccccccc-0000-0000-0000-000000000003','cccccccc-0000-0000-0000-000000000002',
          'GA', 25.00, 100, 'paid', 'public');

CREATE TEMP TABLE v2_tickets (n int, id uuid);

DO $$
DECLARE
  v_ids uuid[];
  t1 uuid; t2 uuid; t3 uuid;
  sec text; own uuid;
  bkt bigint := floor(extract(epoch FROM now())*1000/30000)::bigint;
  payload text; res jsonb; res2 jsonb; cnt int; key uuid := gen_random_uuid();
BEGIN
  PERFORM set_config('app.uid','cccccccc-1111-1111-1111-111111111111', true);
  PERFORM set_config('app.jwt','{"email":"cscanner@x"}', true);

  v_ids := public.exos_mint_tickets('cccccccc-0000-0000-0000-000000000002',
             'cccccccc-0000-0000-0000-000000000003', 3, 'C-COMP', 30, 'promoter-c');
  ASSERT array_length(v_ids,1) = 3, 'mint should return 3 ids';
  INSERT INTO v2_tickets(n,id)
    SELECT row_number() OVER (ORDER BY created_at), id
      FROM public.exos_tickets WHERE event_id='cccccccc-0000-0000-0000-000000000002';
  SELECT id INTO t1 FROM v2_tickets WHERE n=1;
  SELECT id INTO t2 FROM v2_tickets WHERE n=2;
  SELECT id INTO t3 FROM v2_tickets WHERE n=3;

  -- A. valid v2 `T2-h` scan → checked-in
  SELECT barcode_secret, owner_id INTO sec, own FROM public.exos_tickets WHERE id=t1;
  payload := pg_temp.v2payload(t1, own, sec, bkt);
  res := public.exos_check_in_ticket(t1,'camera','verified',payload,'cccccccc-0000-0000-0000-000000000002');
  ASSERT res->>'ok' = 'true' AND res->>'reason' = 'checked-in',
         'A: valid v2 hmac scan must check in, got '||res::text;

  -- B. expired bucket (5 buckets old) → barcode-expired
  SELECT barcode_secret, owner_id INTO sec, own FROM public.exos_tickets WHERE id=t3;
  payload := pg_temp.v2payload(t3, own, sec, bkt - 5);
  res := public.exos_check_in_ticket(t3,'camera','verified',payload,'cccccccc-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'barcode-expired', 'B: stale v2 bucket must be rejected, got '||res::text;

  -- C. tampered signature (wrong secret) → barcode-rejected
  payload := pg_temp.v2payload(t3, own, 'wrong-secret', bkt);
  res := public.exos_check_in_ticket(t3,'camera','verified',payload,'cccccccc-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'barcode-rejected', 'C: forged v2 signature must be rejected, got '||res::text;

  -- D. idempotent replay: same key → stored result, exactly one audit row
  SELECT barcode_secret, owner_id INTO sec, own FROM public.exos_tickets WHERE id=t2;
  payload := pg_temp.v2payload(t2, own, sec, bkt);
  res  := public.exos_check_in_ticket(t2,'camera','verified',payload,'cccccccc-0000-0000-0000-000000000002', key);
  res2 := public.exos_check_in_ticket(t2,'camera','verified',payload,'cccccccc-0000-0000-0000-000000000002', key);
  ASSERT res->>'reason' = 'checked-in',  'D: first idempotent scan must check in, got '||res::text;
  ASSERT res2->>'reason' = 'checked-in', 'D: replay with same key must return the stored result, got '||res2::text;
  SELECT count(*) INTO cnt FROM public.exos_event_checkins WHERE ticket_id = t2;
  ASSERT cnt = 1, 'D: idempotent replay must NOT write a second audit row, got '||cnt;

  -- E. a DIFFERENT key on the now-used ticket → 'used' (no new row)
  res := public.exos_check_in_ticket(t2,'camera','verified',payload,'cccccccc-0000-0000-0000-000000000002', gen_random_uuid());
  ASSERT res->>'reason' = 'used', 'E: second distinct scan of a used ticket must report used, got '||res::text;
  SELECT count(*) INTO cnt FROM public.exos_event_checkins WHERE ticket_id = t2;
  ASSERT cnt = 1, 'E: used-ticket rescan must not add an audit row, got '||cnt;

  RAISE NOTICE 'v2 scan + idempotency ok (valid/expired/forged/idempotent-replay/used)';
END $$;

SELECT '*** MY CHECK-IN (v2 + idempotency) TEST PASSED ***' AS result;
