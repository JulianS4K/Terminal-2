-- ============================================================================
-- Exos ticket-lifecycle regression test. Runs the REAL migrated RPC bodies
-- (see run_lifecycle.sh for the migration chain) end-to-end:
--   mint (with barcodes) → single-call offline roster → HMAC door scan (+ the
--   rejection matrix) → transfer → claim/reissue → void → refuse-after-void.
-- Every step is ASSERT-guarded; ON_ERROR_STOP aborts the run on the first
-- failure so CI goes red. Users are simulated via app.uid / app.jwt GUCs
-- (auth.uid()/auth.jwt() read them — see prereq_lifecycle.sql).
--
-- Actor uuids:
--   organizer 11111111… (org owner + door scanner)   buyer 22222222…
--   receiver  33333333…                               outsider 44444444…
-- Fixed object uuids: org a…01 · event a…02 · tier a…03
-- ============================================================================

-- ── Seed users + profiles (Supabase would create these on signup) ───────────
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('11111111-1111-1111-1111-111111111111','organizer@x', now()),
  ('22222222-2222-2222-2222-222222222222','buyer@x',     now()),
  ('33333333-3333-3333-3333-333333333333','receiver@x',  now()),
  ('44444444-4444-4444-4444-444444444444','outsider@x',  now());
INSERT INTO public.exos_profiles (id, display_name) VALUES
  ('11111111-1111-1111-1111-111111111111','Olivia Organizer'),
  ('22222222-2222-2222-2222-222222222222','Barry Buyer'),
  ('33333333-3333-3333-3333-333333333333','Rita Receiver'),
  ('44444444-4444-4444-4444-444444444444','Oscar Outsider');

-- ── Org + membership + published event (doors already open) + tier ──────────
INSERT INTO public.exos_orgs (id, name, slug, owner_uid)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001','LC Org','lc-org',
          '11111111-1111-1111-1111-111111111111');
INSERT INTO public.exos_org_memberships (org_id, user_id, role)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000001',
          '11111111-1111-1111-1111-111111111111','owner');
INSERT INTO public.exos_events (id, org_id, name, status, doors_at, starts_at, created_by, currency)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001',
          'LC Warehouse Show','published', now() - interval '1 hour', now() + interval '2 hours',
          '11111111-1111-1111-1111-111111111111','USD');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, ticket_type, visibility)
  VALUES ('aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000002',
          'General Admission', 30.00, 100, 'paid', 'public');

CREATE TEMP TABLE lc_tickets (n int, id uuid);

-- ── exos_create_org bootstraps caller as owner (atomic org + membership) ────
DO $$
DECLARE v_org uuid;
BEGIN
  PERFORM set_config('app.uid','22222222-2222-2222-2222-222222222222', true);
  PERFORM set_config('app.jwt','{"email":"buyer@x"}', true);
  v_org := public.exos_create_org('Buyer Side Org','buyer-org');
  ASSERT (SELECT role FROM public.exos_org_memberships
          WHERE org_id = v_org AND user_id = '22222222-2222-2222-2222-222222222222') = 'owner',
         'exos_create_org must bootstrap the caller as owner';
  RAISE NOTICE 'create_org ok';
END $$;

-- ── MINT + single-call offline ROSTER ───────────────────────────────────────
DO $$
DECLARE v_ids uuid[]; v_cnt int; v_secret_ok boolean;
        v_rows int; v_secrets int; v_names int; v_raised boolean := false;
BEGIN
  PERFORM set_config('app.uid','11111111-1111-1111-1111-111111111111', true);
  PERFORM set_config('app.jwt','{"email":"organizer@x"}', true);

  v_ids := public.exos_mint_tickets('aaaaaaaa-0000-0000-0000-000000000002',
             'aaaaaaaa-0000-0000-0000-000000000003', 5, 'LC-COMP', 30, 'promoter-lc');
  ASSERT array_length(v_ids,1) = 5, 'mint should return 5 ticket ids';

  SELECT count(*) INTO v_cnt FROM public.exos_tickets
   WHERE event_id='aaaaaaaa-0000-0000-0000-000000000002' AND status='active';
  ASSERT v_cnt = 5, 'expected 5 active tickets after mint';

  SELECT bool_and(barcode_secret IS NOT NULL AND barcode_secret <> '')
    INTO v_secret_ok FROM public.exos_tickets
   WHERE event_id='aaaaaaaa-0000-0000-0000-000000000002';
  ASSERT v_secret_ok, 'every minted ticket must carry a barcode_secret';

  INSERT INTO lc_tickets(n, id)
    SELECT row_number() OVER (ORDER BY created_at), id
      FROM public.exos_tickets WHERE event_id='aaaaaaaa-0000-0000-0000-000000000002';

  -- one RPC call returns id + owner name + secret for the whole event
  SELECT count(*), count(barcode_secret), count(owner_name)
    INTO v_rows, v_secrets, v_names
    FROM public.exos_event_checkin_roster('aaaaaaaa-0000-0000-0000-000000000002');
  ASSERT v_rows = 5,    'roster should return all 5 tickets';
  ASSERT v_secrets = 5, 'roster must include barcode_secret for every row';
  ASSERT v_names = 5,   'roster must resolve owner display names';

  -- a non-staff caller is refused (42501 → insufficient_privilege)
  PERFORM set_config('app.uid','44444444-4444-4444-4444-444444444444', true);
  PERFORM set_config('app.jwt','{"email":"outsider@x"}', true);
  BEGIN
    PERFORM * FROM public.exos_event_checkin_roster('aaaaaaaa-0000-0000-0000-000000000002');
  EXCEPTION WHEN insufficient_privilege THEN v_raised := true;
  END;
  ASSERT v_raised, 'roster must reject a non-staff caller';
  RAISE NOTICE 'mint + roster ok (5 tickets, secrets + names, outsider blocked)';
END $$;

-- ── Door SCAN with a real signed barcode + rejection matrix ──────────────────
DO $$
DECLARE t1 uuid; t2 uuid; sec text; own uuid; own2 uuid; bkt text; payload text; res jsonb;
BEGIN
  PERFORM set_config('app.uid','11111111-1111-1111-1111-111111111111', true);
  PERFORM set_config('app.jwt','{"email":"organizer@x"}', true);
  SELECT id INTO t1 FROM lc_tickets WHERE n = 1;
  SELECT barcode_secret, owner_id INTO sec, own FROM public.exos_tickets WHERE id = t1;
  bkt := floor(extract(epoch FROM now())*1000/30000)::bigint::text;

  payload := 'T-'||t1||':'||own||':'||bkt||':'||
    rtrim(translate(encode(extensions.hmac(t1||':'||own||':'||bkt, sec, 'sha256'),'base64'),'+/','-_'),'=');
  res := public.exos_check_in_ticket(t1,'camera','verified',payload,'aaaaaaaa-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'checked-in', 'valid signed barcode should check in, got '||res::text;

  res := public.exos_check_in_ticket(t1,'camera','verified',payload,'aaaaaaaa-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'used', 'a second scan of the same ticket must be refused (used)';

  SELECT id INTO t2 FROM lc_tickets WHERE n = 2;
  SELECT owner_id INTO own2 FROM public.exos_tickets WHERE id = t2;
  -- forged HMAC (wrong secret)
  payload := 'T-'||t2||':'||own2||':'||bkt||':'||
    rtrim(translate(encode(extensions.hmac(t2||':'||own2||':'||bkt, 'WRONG-SECRET', 'sha256'),'base64'),'+/','-_'),'=');
  res := public.exos_check_in_ticket(t2,'camera','verified',payload,'aaaaaaaa-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'barcode-rejected', 'forged HMAC must be rejected';
  -- bare-uuid camera scan (the forgery downgrade the doors-gate migration closed)
  res := public.exos_check_in_ticket(t2,'camera','verified', t2::text, 'aaaaaaaa-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'barcode-rejected', 'unsigned camera scan must be rejected';
  -- wrong-event door
  res := public.exos_check_in_ticket(t2,'manual','manual',NULL,'000000ff-0000-0000-0000-0000000000ff');
  ASSERT res->>'reason' = 'wrong-event', 'a ticket scanned at the wrong door must be refused';
  RAISE NOTICE 'scan matrix ok (checked-in / used / barcode-rejected x2 / wrong-event)';
END $$;

-- ── TRANSFER → claim → reissue (the "does it void + reissue?" answer) ────────
DO $$
DECLARE t3 uuid; sec_before text; tr uuid; res jsonb;
        new_owner uuid; new_buyer uuid; new_sec text; st text; vd timestamptz;
        bkt text; payload text;
BEGIN
  SELECT id INTO t3 FROM lc_tickets WHERE n = 3;
  SELECT barcode_secret INTO sec_before FROM public.exos_tickets WHERE id = t3;

  PERFORM set_config('app.uid','11111111-1111-1111-1111-111111111111', true);
  PERFORM set_config('app.jwt','{"email":"organizer@x"}', true);
  tr := public.exos_create_transfer(t3, 'buyer@x');

  -- mid-transfer the ticket is locked: scanning is refused
  res := public.exos_check_in_ticket(t3,'manual','manual',NULL,'aaaaaaaa-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'in-transfer', 'a pending transfer must block check-in';

  -- buyer accepts
  PERFORM set_config('app.uid','22222222-2222-2222-2222-222222222222', true);
  PERFORM set_config('app.jwt','{"email":"buyer@x"}', true);
  PERFORM public.exos_claim_transfer(tr);

  SELECT owner_id, buyer_id, barcode_secret, status, voided_at
    INTO new_owner, new_buyer, new_sec, st, vd
    FROM public.exos_tickets WHERE id = t3;
  ASSERT new_owner = '22222222-2222-2222-2222-222222222222', 'owner must become the claimer';
  ASSERT new_buyer = '22222222-2222-2222-2222-222222222222', 'buyer_id must reassign to the claimer (secret-leak fix)';
  ASSERT new_sec <> sec_before, 'barcode_secret must rotate on claim (the reissue)';
  ASSERT st = 'active',  'transferred ticket stays active';
  ASSERT vd IS NULL,     'transfer must NOT void the original ticket';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE id = t3) = 1,
         'transfer is in-place: still exactly one ticket row (no reissued duplicate)';

  -- the sender's original barcode is now dead
  PERFORM set_config('app.uid','11111111-1111-1111-1111-111111111111', true);
  PERFORM set_config('app.jwt','{"email":"organizer@x"}', true);
  bkt := floor(extract(epoch FROM now())*1000/30000)::bigint::text;
  payload := 'T-'||t3||':11111111-1111-1111-1111-111111111111:'||bkt||':'||
    rtrim(translate(encode(extensions.hmac(
      t3||':11111111-1111-1111-1111-111111111111:'||bkt, sec_before, 'sha256'),'base64'),'+/','-_'),'=');
  res := public.exos_check_in_ticket(t3,'camera','verified',payload,'aaaaaaaa-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'barcode-rejected', 'the sender''s pre-transfer barcode must be dead';
  RAISE NOTICE 'transfer + in-place reissue ok (owner+buyer moved, secret rotated, original not voided)';
END $$;

-- ── VOID (refund) + refuse-after-void ───────────────────────────────────────
DO $$
DECLARE t4 uuid; res jsonb; st text; raised boolean := false;
BEGIN
  SELECT id INTO t4 FROM lc_tickets WHERE n = 4;
  PERFORM set_config('app.uid','11111111-1111-1111-1111-111111111111', true);
  PERFORM set_config('app.jwt','{"email":"organizer@x"}', true);

  PERFORM public.exos_void_ticket(t4, 'customer refund');
  SELECT status INTO st FROM public.exos_tickets WHERE id = t4;
  ASSERT st = 'voided', 'void must set status = voided';

  res := public.exos_check_in_ticket(t4,'manual','manual',NULL,'aaaaaaaa-0000-0000-0000-000000000002');
  ASSERT res->>'reason' = 'voided', 'a voided ticket must not check in';

  BEGIN
    PERFORM public.exos_create_transfer(t4, 'buyer@x');
  EXCEPTION WHEN others THEN raised := true;
  END;
  ASSERT raised, 'transferring a voided ticket must raise';
  RAISE NOTICE 'void + refuse-after-void ok';
END $$;

SELECT '*** EXOS TICKET-LIFECYCLE TEST PASSED ***' AS result;
