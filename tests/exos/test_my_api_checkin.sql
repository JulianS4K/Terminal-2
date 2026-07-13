-- ============================================================================
-- Regression for migration 20260713170000 (programmatic REST check-in). Drives
-- the service-role exos_api_check_in_ticket RPC: org-scoped, signed-barcode
-- required, atomic single-use, idempotent, audited as source='api'. Self-seeded
-- (eeee… uuids). Runs after the chain + 20260713120000 + 20260713170000.
-- ============================================================================

CREATE FUNCTION pg_temp.leb128(n bigint) RETURNS bytea LANGUAGE plpgsql AS $$
DECLARE b bytea := ''; v bigint := n; byte int;
BEGIN
  LOOP
    byte := (v % 128)::int; v := v / 128;
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
  msg := decode(replace(tid::text,'-',''),'hex') || decode(replace(oid::text,'-',''),'hex') || pg_temp.leb128(bucket);
  sig := substring(extensions.hmac(msg, convert_to(coalesce(secret,''),'UTF8'), 'sha256') for 16);
  RETURN 'T2-h' || rtrim(translate(encode(msg || sig, 'base64'), '+/', '-_'), '=');
END $$;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('eeeeeeee-1111-1111-1111-111111111111','eowner@x', now());
INSERT INTO public.exos_profiles (id, display_name) VALUES
  ('eeeeeeee-1111-1111-1111-111111111111','Eve Owner');
INSERT INTO public.exos_orgs (id, name, slug, owner_uid)
  VALUES ('eeeeeeee-0000-0000-0000-000000000001','API Org','api-org','eeeeeeee-1111-1111-1111-111111111111');
INSERT INTO public.exos_org_memberships (org_id, user_id, role)
  VALUES ('eeeeeeee-0000-0000-0000-000000000001','eeeeeeee-1111-1111-1111-111111111111','owner');
INSERT INTO public.exos_events (id, org_id, name, status, doors_at, starts_at, created_by, currency)
  VALUES ('eeeeeeee-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001',
          'API Show','published', now() - interval '1 hour', now() + interval '2 hours',
          'eeeeeeee-1111-1111-1111-111111111111','USD');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, ticket_type, visibility)
  VALUES ('eeeeeeee-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000002','GA',20,100,'paid','public');

DO $$
DECLARE
  v_ids uuid[]; t1 uuid; t2 uuid; sec text; own uuid;
  bkt bigint := floor(extract(epoch FROM now())*1000/30000)::bigint;
  org uuid := 'eeeeeeee-0000-0000-0000-000000000001';
  apikey uuid := gen_random_uuid(); key uuid := gen_random_uuid();
  payload text; res jsonb; res2 jsonb; cnt int; src text; who uuid;
BEGIN
  PERFORM set_config('app.uid','eeeeeeee-1111-1111-1111-111111111111', true);
  PERFORM set_config('app.jwt','{"email":"eowner@x"}', true);
  v_ids := public.exos_mint_tickets('eeeeeeee-0000-0000-0000-000000000002',
             'eeeeeeee-0000-0000-0000-000000000003', 2, 'E-COMP', 30, 'promoter-e');
  -- Use the returned ids directly — minted tickets share created_at, so an
  -- ORDER BY created_at LIMIT 1 is non-deterministic and can alias t1 = t2.
  t1 := v_ids[1];
  t2 := v_ids[2];

  -- A. no barcode → barcode-required
  res := public.exos_api_check_in_ticket(org, t1, NULL, NULL, apikey);
  ASSERT res->>'reason' = 'barcode-required', 'A: API check-in must require a signed barcode, got '||res::text;

  -- B. wrong org → wrong-org (a key can't check in another org's ticket)
  SELECT barcode_secret, owner_id INTO sec, own FROM public.exos_tickets WHERE id=t1;
  payload := pg_temp.v2payload(t1, own, sec, bkt);
  res := public.exos_api_check_in_ticket(gen_random_uuid(), t1, payload, NULL, apikey);
  ASSERT res->>'reason' = 'wrong-org', 'B: mismatched org must be refused, got '||res::text;

  -- C. valid v2 scan under the right org → checked-in, audited as source=api
  res := public.exos_api_check_in_ticket(org, t1, payload, NULL, apikey);
  ASSERT res->>'ok' = 'true' AND res->>'reason' = 'checked-in', 'C: valid API scan must check in, got '||res::text;
  SELECT source, scanned_by, api_key_id INTO src, who, apikey FROM public.exos_event_checkins WHERE ticket_id = t1;
  ASSERT src = 'api', 'C: audit row source must be api, got '||coalesce(src,'<null>');
  ASSERT who IS NULL, 'C: API check-in must record scanned_by NULL';

  -- D. idempotent replay → same result, one audit row
  SELECT barcode_secret, owner_id INTO sec, own FROM public.exos_tickets WHERE id=t2;
  payload := pg_temp.v2payload(t2, own, sec, bkt);
  res  := public.exos_api_check_in_ticket(org, t2, payload, key, gen_random_uuid());
  res2 := public.exos_api_check_in_ticket(org, t2, payload, key, gen_random_uuid());
  ASSERT res->>'reason'  = 'checked-in', 'D: first API idempotent scan must check in, got '||res::text;
  ASSERT res2->>'reason' = 'checked-in', 'D: replay same key must return stored result, got '||res2::text;
  SELECT count(*) INTO cnt FROM public.exos_event_checkins WHERE ticket_id = t2;
  ASSERT cnt = 1, 'D: idempotent API replay must not double-audit, got '||cnt;

  RAISE NOTICE 'API check-in ok (barcode-required / wrong-org / valid+audited / idempotent)';
END $$;

SELECT '*** MY API CHECK-IN TEST PASSED ***' AS result;
