-- ============================================================================
-- Comprehensive offline test for the Exos (D4/Bridge) feature migrations.
--   PART A — each function/trigger individually.
--   PART B — the whole platform end-to-end (one realistic lifecycle).
--
-- Run against the minimal harness in this dir:
--   psql ... -f prereq.sql
--   psql ... -f <each exos migration, in order>
--   psql ... -f test_exos_platform.sql      (see run.sh)
-- Any failed ASSERT aborts with ON_ERROR_STOP; a clean run ends "ALL ... PASSED".
-- ============================================================================
\set ON_ERROR_STOP on

-- Common actors.
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('11111111-1111-1111-1111-111111111111','owner@s4kent.com',now()),
  ('22222222-2222-2222-2222-222222222222','buyer@x.com',now());

-- ============================================================================
-- PART A — INDIVIDUAL FUNCTIONS
-- ============================================================================
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','OrgA','orga','11111111-1111-1111-1111-111111111111');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','EvtA','evta','published',100,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-0000000000e1','GA',50,100,0);
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity,sold,max_per_order,visibility) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-0000000000e1','Tee',25,10,0,3,'public'),
  ('aaaaaaaa-0000-0000-0000-0000000000a2','aaaaaaaa-0000-0000-0000-0000000000e1','Free Sticker',0,5,0,NULL,'public');

-- A1. Waitlist join / dedupe / leave / notify / summary -----------------------
SELECT set_config('app.uid','',false);
DO $$
DECLARE r record; n int;
BEGIN
  SELECT * INTO r FROM public.exos_join_waitlist('aaaaaaaa-0000-0000-0000-0000000000e1','a@x.com',NULL,'Al',2);
  ASSERT r.queue_position = 1, 'join position';
  PERFORM public.exos_join_waitlist('aaaaaaaa-0000-0000-0000-0000000000e1','a@x.com');  -- dedupe
  PERFORM public.exos_join_waitlist('aaaaaaaa-0000-0000-0000-0000000000e1','b@x.com');
  SELECT count(*) INTO n FROM public.exos_waitlist WHERE event_id='aaaaaaaa-0000-0000-0000-0000000000e1';
  ASSERT n = 2, 'dedupe → 2 rows';
  -- Leave now requires the caller's JWT identity (mig 20260702144607): a client
  -- p_email alone no longer authorizes. Simulate the signed-in session whose
  -- verified email matches the anon-created row.
  PERFORM set_config('app.jwt','{"email":"b@x.com"}',false);
  ASSERT public.exos_leave_waitlist((SELECT id FROM public.exos_waitlist WHERE email='b@x.com'),NULL), 'leave';
  PERFORM set_config('app.jwt','',false);
  RAISE NOTICE 'A1 waitlist join/dedupe/leave OK';
END $$;
SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE n int; r record;
BEGIN
  SELECT public.exos_notify_waitlist('aaaaaaaa-0000-0000-0000-0000000000e1',5) INTO n;
  ASSERT n = 1, 'notify the 1 remaining waiter';
  SELECT * INTO r FROM public.exos_waitlist_summary('aaaaaaaa-0000-0000-0000-0000000000e1');
  ASSERT r.notified = 1, 'summary notified';
  RAISE NOTICE 'A1 waitlist notify/summary OK';
END $$;

-- A2. Add-ons: fulfill (records + sold), refund (reverses), free claim --------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,addons)
VALUES ('A-s1','aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-0000000000d1',
        'aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','buyer@x.com',2,15000,'pending',
        '[{"addon_id":"aaaaaaaa-0000-0000-0000-0000000000a1","quantity":2,"unit_price_cents":2500,"name":"Tee"}]'::jsonb);
DO $$
DECLARE ids uuid[]; v_sold int; n int;
BEGIN
  ids := public.exos_fulfill_checkout('A-s1');
  ASSERT array_length(ids,1) = 2, 'mint 2';
  SELECT sold INTO v_sold FROM public.exos_event_addons WHERE id='aaaaaaaa-0000-0000-0000-0000000000a1';
  ASSERT v_sold = 2, 'addon sold=2';
  PERFORM public.exos_fulfill_checkout('A-s1');  -- idempotent
  SELECT count(*) INTO n FROM public.exos_tickets WHERE order_ref='A-s1';
  ASSERT n = 2, 'idempotent mint';
  PERFORM public.exos_refund_checkout('A-s1');
  SELECT sold INTO v_sold FROM public.exos_event_addons WHERE id='aaaaaaaa-0000-0000-0000-0000000000a1';
  ASSERT v_sold = 0, 'addon stock freed';
  RAISE NOTICE 'A2 addon fulfill/idempotent/refund OK';
END $$;
SELECT set_config('app.uid','22222222-2222-2222-2222-222222222222',false);
DO $$
DECLARE n int;
BEGIN
  SELECT public.exos_claim_free_addons('aaaaaaaa-0000-0000-0000-0000000000e1','A-free',
    '[{"addon_id":"aaaaaaaa-0000-0000-0000-0000000000a2","quantity":1}]'::jsonb) INTO n;
  ASSERT n = 1, 'free addon claim';
  BEGIN
    PERFORM public.exos_claim_free_addons('aaaaaaaa-0000-0000-0000-0000000000e1','A-free2',
      '[{"addon_id":"aaaaaaaa-0000-0000-0000-0000000000a1","quantity":1}]'::jsonb);
    RAISE EXCEPTION 'paid addon should be rejected on free path';
  EXCEPTION WHEN others THEN ASSERT sqlerrm LIKE '%not free%', 'paid reject'; END;
  RAISE NOTICE 'A2 free-addon claim + paid-reject OK';
END $$;

-- A3. API keys: create (hash-at-rest) / list (no hash) / revoke ----------------
SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE k text; h text; kid uuid; n int;
BEGIN
  k := public.exos_create_api_key('aaaaaaaa-0000-0000-0000-000000000001','CI');
  ASSERT k LIKE 'sk_live_%', 'key fmt';
  SELECT key_hash, id INTO h, kid FROM public.exos_api_keys WHERE org_id='aaaaaaaa-0000-0000-0000-000000000001';
  ASSERT h = encode(extensions.digest(k,'sha256'),'hex') AND h <> k, 'hash-at-rest';
  SELECT count(*) INTO n FROM public.exos_list_api_keys('aaaaaaaa-0000-0000-0000-000000000001');
  ASSERT n = 1, 'list';
  ASSERT public.exos_revoke_api_key(kid), 'revoke';
  RAISE NOTICE 'A3 api keys OK';
END $$;

-- A4. Vouchers: issue / check (valid/reserved/invalid) / consume ---------------
DO $$
DECLARE v_code text; r record;
BEGIN
  v_code := public.exos_issue_voucher('aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-0000000000d1','vip@x.com',true,NULL,1,48,'t');
  SELECT * INTO r FROM public.exos_check_voucher('aaaaaaaa-0000-0000-0000-0000000000e1',v_code,'vip@x.com');
  ASSERT r.is_valid AND r.can_bypass, 'valid+bypass';
  SELECT * INTO r FROM public.exos_check_voucher('aaaaaaaa-0000-0000-0000-0000000000e1',v_code,'other@x.com');
  ASSERT NOT r.is_valid AND r.reason='reserved for another buyer', 'reserved guard';
  SELECT * INTO r FROM public.exos_check_voucher('aaaaaaaa-0000-0000-0000-0000000000e1','BAD','vip@x.com');
  ASSERT NOT r.is_valid AND r.reason='invalid code', 'invalid';
  ASSERT public.exos_consume_voucher((SELECT id FROM public.exos_vouchers WHERE code=v_code)), 'consume';
  ASSERT NOT public.exos_consume_voucher((SELECT id FROM public.exos_vouchers WHERE code=v_code)), 'no double-consume';
  RAISE NOTICE 'A4 vouchers OK';
END $$;

-- A5. Tax math (exclusive/inclusive/zero/null) --------------------------------
DO $$
BEGIN
  ASSERT public.exos_tax_cents(10000,20,false)=2000 AND public.exos_tax_cents(12000,20,true)=2000
     AND public.exos_tax_cents(10000,0,false)=0 AND public.exos_tax_cents(10000,NULL,false)=0, 'tax math';
  RAISE NOTICE 'A5 tax math OK';
END $$;

-- A6. Invoicing: sequential numbers --------------------------------------------
DO $$
DECLARE a text; b text;
BEGIN
  -- (orgA already issued INV-000001 from the A2 fulfillment trigger — the point
  --  is that numbers are consecutive + well-formed, regardless of start.)
  a := public.exos_next_invoice_number('aaaaaaaa-0000-0000-0000-000000000001');
  b := public.exos_next_invoice_number('aaaaaaaa-0000-0000-0000-000000000001');
  ASSERT a LIKE 'INV-%' AND b LIKE 'INV-%', 'format';
  ASSERT (substring(b from 5))::int = (substring(a from 5))::int + 1, 'consecutive, got '||a||' / '||b;
  RAISE NOTICE 'A6 invoice numbering OK (% then %)', a, b;
END $$;

-- A7. Voucher bypass_capacity mints on a genuinely SOLD-OUT tier (audit fix) ----
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000d2','aaaaaaaa-0000-0000-0000-0000000000e1','VIP',200,1,1);  -- sold out
SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE vcode text; vid uuid; ids uuid[]; st text;
BEGIN
  vcode := public.exos_issue_voucher('aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-0000000000d2',NULL,true,NULL,1,NULL,'oversell');
  SELECT id INTO vid FROM public.exos_vouchers WHERE code=vcode;
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,voucher_id)
  VALUES ('A-bypass','aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-0000000000d2',
          'aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','buyer@x.com',1,20000,'pending',vid);
  ids := public.exos_fulfill_checkout('A-bypass');
  ASSERT array_length(ids,1)=1, 'bypass voucher mints on sold-out tier';
  SELECT status INTO st FROM public.exos_checkout_sessions WHERE session_id='A-bypass';
  ASSERT st='fulfilled', 'session fulfilled not failed, got '||st;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='aaaaaaaa-0000-0000-0000-0000000000d2')=2, 'oversold 1 to 2';
  RAISE NOTICE 'A7 voucher bypass mints on sold-out tier OK (audit fix)';
END $$;

-- A8. Voucher single-use is atomic across concurrent sessions (audit 2026-07-02).
-- One single-use voucher shared by two paid sessions → exactly ONE fulfills.
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000d3','aaaaaaaa-0000-0000-0000-0000000000e1','GA8',100,50,0);
SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE vcode text; vid uuid; ids1 uuid[]; ids2 uuid[]; st1 text; st2 text; uc int;
BEGIN
  vcode := public.exos_issue_voucher('aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-0000000000d3',NULL,true,NULL,1,NULL,'single-use');
  SELECT id INTO vid FROM public.exos_vouchers WHERE code=vcode;
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,voucher_id) VALUES
    ('A-vu1','aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-0000000000d3','aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','vu@x.com',1,10000,'pending',vid),
    ('A-vu2','aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-0000000000d3','aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','vu@x.com',1,10000,'pending',vid);
  ids1 := public.exos_fulfill_checkout('A-vu1');
  ids2 := public.exos_fulfill_checkout('A-vu2');   -- voucher now exhausted
  SELECT status INTO st1 FROM public.exos_checkout_sessions WHERE session_id='A-vu1';
  SELECT status INTO st2 FROM public.exos_checkout_sessions WHERE session_id='A-vu2';
  SELECT used_count INTO uc FROM public.exos_vouchers WHERE id=vid;
  ASSERT array_length(ids1,1)=1 AND st1='fulfilled', 'first redemption mints, got '||st1;
  ASSERT coalesce(array_length(ids2,1),0)=0 AND st2='failed', 'second redemption of single-use voucher must fail, got '||st2;
  ASSERT uc=1, 'voucher used_count stays 1 (not double-consumed), got '||uc;
  RAISE NOTICE 'A8 voucher single-use atomic across sessions OK (audit fix)';
END $$;

-- A9. Check-in hardening + doors gate (audit 2026-07-02).
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,doors_at,total_tickets)
  VALUES ('aaaaaaaa-0000-0000-0000-0000000000e9','aaaaaaaa-0000-0000-0000-000000000001','Doors Test',
          'published', now()+interval '3 hours', now()+interval '2 hours', 100);
INSERT INTO public.exos_tickets(id,event_id,org_id,owner_id,buyer_id,status,barcode_secret) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000f1','aaaaaaaa-0000-0000-0000-0000000000e9','aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','active','secret-f1'),
  ('aaaaaaaa-0000-0000-0000-0000000000f2','aaaaaaaa-0000-0000-0000-0000000000e9','aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','active','secret-f2');
SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);  -- org owner = door staff
SELECT set_config('app.jwt','{"email":"owner@x.com"}',false);
DO $$
DECLARE r jsonb; bkt bigint; sig text; oid text := '22222222-2222-2222-2222-222222222222';
        tid1 text := 'aaaaaaaa-0000-0000-0000-0000000000f1';
        tid2 text := 'aaaaaaaa-0000-0000-0000-0000000000f2';
BEGIN
  -- (a) Before doors, test mode off → rejected.
  r := public.exos_check_in_ticket(tid1::uuid,'manual','manual',NULL,'aaaaaaaa-0000-0000-0000-0000000000e9');
  ASSERT r->>'reason'='doors-not-open', 'pre-doors check-in must be blocked, got '||coalesce(r->>'reason','null');

  -- Bare boolean alone must NOT lift the gate (mig 20260702144537 requires an
  -- unexpired checkin_test_until — closes the "left on forever" footgun).
  UPDATE public.exos_events SET checkin_test_mode=true, checkin_test_until=NULL
    WHERE id='aaaaaaaa-0000-0000-0000-0000000000e9';
  r := public.exos_check_in_ticket(tid1::uuid,'manual','manual',NULL,'aaaaaaaa-0000-0000-0000-0000000000e9');
  ASSERT r->>'reason'='doors-not-open', 'bare test-mode boolean must NOT lift the gate, got '||coalesce(r->>'reason','null');

  -- Open a bounded test window via the RPC (owner-gated) → gate lifted.
  PERFORM public.exos_set_checkin_test_window('aaaaaaaa-0000-0000-0000-0000000000e9', 3);

  -- (b) Valid signed barcode via camera → admitted.
  bkt := floor(extract(epoch FROM now())*1000/30000)::bigint;
  sig := rtrim(translate(encode(extensions.hmac(tid1||':'||oid||':'||bkt::text,'secret-f1','sha256'),'base64'),'+/','-_'),'=');
  r := public.exos_check_in_ticket(tid1::uuid,'camera','verified','T-'||tid1||':'||oid||':'||bkt::text||':'||sig,'aaaaaaaa-0000-0000-0000-0000000000e9');
  ASSERT (r->>'ok')::boolean, 'valid signed barcode must be admitted, got '||coalesce(r->>'reason','null');

  -- (c) Legacy 3-segment payload via camera → rejected (downgrade closed).
  r := public.exos_check_in_ticket(tid2::uuid,'camera','legacy','T-'||tid2||':'||oid||':'||bkt::text,'aaaaaaaa-0000-0000-0000-0000000000e9');
  ASSERT r->>'reason'='barcode-rejected', 'legacy 3-seg barcode must be rejected, got '||coalesce(r->>'reason','null');
  ASSERT (SELECT status FROM public.exos_tickets WHERE id=tid2::uuid)='active', 'rejected legacy scan must NOT flip the ticket';

  -- (d) Camera scan with no signed payload (bare UUID) → rejected.
  r := public.exos_check_in_ticket(tid2::uuid,'camera','manual',NULL,'aaaaaaaa-0000-0000-0000-0000000000e9');
  ASSERT r->>'reason'='barcode-rejected', 'bare camera scan must be rejected, got '||coalesce(r->>'reason','null');

  -- (e) Manual typed entry (authorized staff, no payload) → admitted.
  r := public.exos_check_in_ticket(tid2::uuid,'manual','manual',NULL,'aaaaaaaa-0000-0000-0000-0000000000e9');
  ASSERT (r->>'ok')::boolean, 'manual staff override must be admitted, got '||coalesce(r->>'reason','null');
  RAISE NOTICE 'A9 check-in doors gate + barcode hardening OK (audit fix)';
END $$;

-- A10. Transfer no longer leaks the rotated barcode_secret to the old buyer
-- (audit 2026-07-02): claim reassigns buyer_id to the claimer.
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('33333333-3333-3333-3333-333333333333','alice@x.com',now()),
  ('44444444-4444-4444-4444-444444444444','bob@x.com',now())
  ON CONFLICT (id) DO NOTHING;
INSERT INTO public.exos_tickets(id,event_id,org_id,owner_id,buyer_id,status,barcode_secret,pending_transfer_id) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000f3','aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','33333333-3333-3333-3333-333333333333','active','secret-old','aaaaaaaa-0000-0000-0000-0000000000c1');
INSERT INTO public.exos_transfers(id,ticket_id,org_id,sender_id,receiver_email,status) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-0000000000f3','aaaaaaaa-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','bob@x.com','pending');
SELECT set_config('app.uid','44444444-4444-4444-4444-444444444444',false);  -- Bob claims
SELECT set_config('app.jwt','{"email":"bob@x.com"}',false);
DO $$
DECLARE o uuid; b uuid; sec text; st text; ptid uuid;
BEGIN
  PERFORM public.exos_claim_transfer('aaaaaaaa-0000-0000-0000-0000000000c1');
  SELECT owner_id,buyer_id,barcode_secret,status,pending_transfer_id
    INTO o,b,sec,st,ptid FROM public.exos_tickets WHERE id='aaaaaaaa-0000-0000-0000-0000000000f3';
  ASSERT o='44444444-4444-4444-4444-444444444444', 'owner reassigned to claimer';
  ASSERT b='44444444-4444-4444-4444-444444444444', 'buyer_id reassigned to claimer (old buyer loses RLS read)';
  ASSERT sec<>'secret-old', 'barcode_secret rotated on claim';
  ASSERT st='active' AND ptid IS NULL, 'ticket active + transfer lock cleared';
  RAISE NOTICE 'A10 transfer reassigns buyer_id (secret leak closed) OK (audit fix)';
END $$;

-- A11. Test-mode window auto-expires (real-event hardening 2026-07-02).
INSERT INTO public.exos_tickets(id,event_id,org_id,owner_id,buyer_id,status,barcode_secret) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000f4','aaaaaaaa-0000-0000-0000-0000000000e9','aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','active','secret-f4');
SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
SELECT set_config('app.jwt','{"email":"owner@s4kent.com"}',false);
DO $$
DECLARE r jsonb;
BEGIN
  -- A lapsed window (checkin_test_until in the past) must re-block, even with
  -- checkin_test_mode still true.
  UPDATE public.exos_events SET checkin_test_mode=true, checkin_test_until=now()-interval '1 minute'
    WHERE id='aaaaaaaa-0000-0000-0000-0000000000e9';
  r := public.exos_check_in_ticket('aaaaaaaa-0000-0000-0000-0000000000f4','manual','manual',NULL,'aaaaaaaa-0000-0000-0000-0000000000e9');
  ASSERT r->>'reason'='doors-not-open', 'expired test window must re-block the gate, got '||coalesce(r->>'reason','null');

  -- Clearing via the RPC (p_hours<=0) drops the flag + window.
  PERFORM public.exos_set_checkin_test_window('aaaaaaaa-0000-0000-0000-0000000000e9', 0);
  ASSERT (SELECT NOT checkin_test_mode AND checkin_test_until IS NULL
            FROM public.exos_events WHERE id='aaaaaaaa-0000-0000-0000-0000000000e9'),
         'clearing the window resets both fields';
  RAISE NOTICE 'A11 test-mode window auto-expiry OK (audit fix)';
END $$;

-- A12. Waitlist IDOR closed (mig 20260702144607): client email can't tamper/
-- cancel another user's row. Uses published event e9 + the auth.users from A10.
DO $$
DECLARE alice_row uuid; nm text; st text; raised boolean := false;
BEGIN
  PERFORM set_config('app.uid','33333333-3333-3333-3333-333333333333',false);
  PERFORM set_config('app.jwt','{"email":"alice@x.com"}',false);
  SELECT waitlist_id INTO alice_row FROM public.exos_join_waitlist(
    'aaaaaaaa-0000-0000-0000-0000000000e9','ignored@x.com',NULL,'Alice',2,NULL);
  ASSERT (SELECT user_id FROM public.exos_waitlist WHERE id=alice_row)='33333333-3333-3333-3333-333333333333',
         'authed join binds row to the JWT user';

  -- Anon caller who knows Alice's email must NOT be able to touch her row.
  PERFORM set_config('app.uid','',false);
  PERFORM set_config('app.jwt','{}',false);
  BEGIN
    PERFORM public.exos_join_waitlist('aaaaaaaa-0000-0000-0000-0000000000e9','alice@x.com',NULL,'HACKED',9,NULL);
  EXCEPTION WHEN others THEN raised := true;
  END;
  ASSERT raised, 'anon join on a registered email must be refused';
  SELECT name INTO nm FROM public.exos_waitlist WHERE id=alice_row;
  ASSERT nm='Alice', 'victim row must be untouched, got '||coalesce(nm,'null');

  -- A different authenticated user supplying Alice's email only affects THEIR own row.
  PERFORM set_config('app.uid','44444444-4444-4444-4444-444444444444',false);
  PERFORM set_config('app.jwt','{"email":"bob@x.com"}',false);
  PERFORM public.exos_join_waitlist('aaaaaaaa-0000-0000-0000-0000000000e9','alice@x.com',NULL,'Bob',1,NULL);
  ASSERT (SELECT count(*) FROM public.exos_waitlist WHERE event_id='aaaaaaaa-0000-0000-0000-0000000000e9' AND email='bob@x.com')=1,
         'attacker join creates only their own row';
  ASSERT (SELECT user_id FROM public.exos_waitlist WHERE id=alice_row)='33333333-3333-3333-3333-333333333333',
         'attacker cannot rebind the victim row';

  -- Anon leave with a client-supplied email must NOT cancel Alice's row.
  PERFORM set_config('app.uid','',false);
  PERFORM set_config('app.jwt','{}',false);
  PERFORM public.exos_leave_waitlist(alice_row,'alice@x.com');
  SELECT status INTO st FROM public.exos_waitlist WHERE id=alice_row;
  ASSERT st='waiting', 'client-email leave must not cancel the victim row, got '||st;

  -- Alice herself can leave (JWT identity).
  PERFORM set_config('app.uid','33333333-3333-3333-3333-333333333333',false);
  PERFORM set_config('app.jwt','{"email":"alice@x.com"}',false);
  PERFORM public.exos_leave_waitlist(alice_row,NULL);
  ASSERT (SELECT status FROM public.exos_waitlist WHERE id=alice_row)='cancelled', 'owner can cancel their own row';
  RAISE NOTICE 'A12 waitlist IDOR closed OK (audit fix)';
END $$;

SELECT '*** PART A (individual functions) PASSED ***' AS result;

-- ============================================================================
-- PART B — COLLECTIVE END-TO-END (one event's full lifecycle)
--   publish → buy(tax+addon) → invoice → sell out → waitlist → refund →
--   auto-offer voucher → redeem → convert → second invoice. Asserts every
--   subsystem moved together.
-- ============================================================================
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001','OrgB','orgb','11111111-1111-1111-1111-111111111111');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold) VALUES
  ('bbbbbbbb-0000-0000-0000-0000000000e1','bbbbbbbb-0000-0000-0000-000000000001','Finale','finale','draft',2,0);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('bbbbbbbb-0000-0000-0000-0000000000d1','bbbbbbbb-0000-0000-0000-0000000000e1','GA',100,2,0);
INSERT INTO public.exos_tax_rules(id,event_id,name,rate_percent,price_includes_tax) VALUES
  ('bbbbbbbb-0000-0000-0000-0000000000c1','bbbbbbbb-0000-0000-0000-0000000000e1','VAT 20%',20,false);
UPDATE public.exos_ticket_tiers SET tax_rate_id='bbbbbbbb-0000-0000-0000-0000000000c1' WHERE id='bbbbbbbb-0000-0000-0000-0000000000d1';
INSERT INTO public.exos_webhooks(id,org_id,url,event_types,enabled) VALUES
  ('bbbbbbbb-0000-0000-0000-0000000000f1','bbbbbbbb-0000-0000-0000-000000000001','https://hook.example.com',ARRAY['*'],true);

-- 1) publish → event.published webhook
UPDATE public.exos_events SET status='published' WHERE id='bbbbbbbb-0000-0000-0000-0000000000e1';

-- 2) buyer1 buys 2 (sells out) with exclusive tax (2*100*20% = $40 tax → 12000+4000=24000 wait:
--    net 2*100=200 → 20000c; tax 20% = 4000c; total 24000c). Fulfill.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,tax_cents,status)
VALUES ('B-s1','bbbbbbbb-0000-0000-0000-0000000000e1','bbbbbbbb-0000-0000-0000-0000000000d1',
        'bbbbbbbb-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','buyer@x.com',2,24000,4000,'pending');
-- fulfill itself claims the tier + event capacity (sold 0->2 = sold out).
DO $$ DECLARE ids uuid[]; BEGIN ids := public.exos_fulfill_checkout('B-s1'); ASSERT array_length(ids,1)=2,'mint 2'; END $$;

DO $$
DECLARE inv record; pub int; ful int; tic int;
BEGIN
  -- invoice INV-000001 issued with the tax split
  SELECT * INTO inv FROM public.exos_invoices WHERE session_id='B-s1';
  ASSERT inv.number='INV-000001', 'first invoice number, got '||coalesce(inv.number,'null');
  ASSERT inv.total_cents=24000 AND inv.tax_cents=4000 AND inv.subtotal_cents=20000, 'invoice split';
  -- webhooks
  SELECT count(*) INTO pub FROM public.exos_webhook_deliveries WHERE org_id='bbbbbbbb-0000-0000-0000-000000000001' AND event_type='event.published';
  SELECT count(*) INTO ful FROM public.exos_webhook_deliveries WHERE org_id='bbbbbbbb-0000-0000-0000-000000000001' AND event_type='order.fulfilled';
  SELECT count(*) INTO tic FROM public.exos_webhook_deliveries WHERE org_id='bbbbbbbb-0000-0000-0000-000000000001' AND event_type='ticket.created';
  ASSERT pub=1 AND ful=1 AND tic=2, format('webhooks pub=%s ful=%s tic=%s', pub, ful, tic);
  RAISE NOTICE 'B step 2: buy → invoice + webhooks OK';
END $$;

-- 3) buyer2 joins the (now sold-out) waitlist
SELECT set_config('app.uid','',false);
DO $$ BEGIN PERFORM public.exos_join_waitlist('bbbbbbbb-0000-0000-0000-0000000000e1','buyer2@x.com',NULL,'Two',1); END $$;

-- 4) refund buyer1 → tickets void, tier.sold drops → AUTO-OFFER fires for buyer2;
--    invoice flips refunded; order.refunded webhook.
DO $$ DECLARE n int; BEGIN
  SELECT public.exos_refund_checkout('B-s1') INTO n; ASSERT n=2, 'refund voids 2';
END $$;
-- refund freed tier inventory (2 → 0); trigger auto-offered buyer2
DO $$
DECLARE st text; vcode text; inv_st text; refw int;
BEGIN
  SELECT w.status, v.code INTO st, vcode
  FROM public.exos_waitlist w LEFT JOIN public.exos_vouchers v ON v.id=w.voucher_id
  WHERE w.email='buyer2@x.com';
  ASSERT st='offered', 'buyer2 auto-offered, got '||st;
  ASSERT vcode IS NOT NULL, 'offer minted a voucher';
  SELECT status INTO inv_st FROM public.exos_invoices WHERE session_id='B-s1';
  ASSERT inv_st='refunded', 'invoice refunded';
  SELECT count(*) INTO refw FROM public.exos_webhook_deliveries WHERE org_id='bbbbbbbb-0000-0000-0000-000000000001' AND event_type='order.refunded';
  ASSERT refw=1, 'order.refunded webhook';
  RAISE NOTICE 'B step 4: refund → auto-offer + invoice flip + webhook OK';
END $$;

-- 5) buyer2 redeems the offered voucher at checkout (bypass) → fulfill →
--    waitlist converts, voucher consumed, invoice INV-000002.
DO $$
DECLARE vid uuid; st text; inv2 text;
BEGIN
  SELECT voucher_id INTO vid FROM public.exos_waitlist WHERE email='buyer2@x.com';
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,tax_cents,status,voucher_id)
  VALUES ('B-s2','bbbbbbbb-0000-0000-0000-0000000000e1','bbbbbbbb-0000-0000-0000-0000000000d1',
          'bbbbbbbb-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','buyer2@x.com',1,12000,2000,'pending',vid);
  -- Consume now happens INSIDE exos_fulfill_checkout (mig 20260702122000 moved
  -- it off the AFTER trigger and dropped that trigger), so drive the real
  -- fulfillment path rather than manually flipping status.
  PERFORM public.exos_fulfill_checkout('B-s2');
  SELECT status INTO st FROM public.exos_waitlist WHERE email='buyer2@x.com';
  ASSERT st='converted', 'waitlist converted on redeem, got '||st;
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE id=vid)=1, 'voucher consumed';
  SELECT number INTO inv2 FROM public.exos_invoices WHERE session_id='B-s2';
  ASSERT inv2='INV-000002', 'second invoice sequential, got '||coalesce(inv2,'null');
  RAISE NOTICE 'B step 5: voucher redeem → convert + consume + invoice #2 OK';
END $$;

SELECT '*** PART B (end-to-end platform) PASSED ***' AS result;
-- ============================================================================
-- PART C — PRE-EVENT REMINDERS (mig 20260911051000)
--   cron entry (T-24h / T-2h, once each, catch-up safe) · manual send + cooldown
--   · role gate · postpone resets the cycle · invoice-counter RLS (mig 050000).
-- ============================================================================
SELECT set_config('app.uid','',false);
SELECT set_config('app.jwt','',false);
-- Isolate from Parts A/B: their events (some published inside the windows by
-- the doors-gate tests) are treated as already reminded.
UPDATE public.exos_events SET reminder_24h_sent_at = now(), reminder_2h_sent_at = now();
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('55555555-5555-5555-5555-555555555555','holder2@x.com',now()),
  ('66666666-6666-6666-6666-666666666666','voided@x.com',now());
-- Event C: published, starts in 20h (inside the 24h window, outside 2h), NY tz.
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold,starts_at,doors_at,timezone,venue_name) VALUES
  ('cccccccc-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','Evt <C>','evtc','published',10,3,
   now()+interval '20 hours', now()+interval '19 hours', 'America/New_York', 'Brooklyn Steel');
-- Event D: published but starts in 5 days — nothing due.
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,starts_at,timezone) VALUES
  ('cccccccc-0000-0000-0000-0000000000e2','aaaaaaaa-0000-0000-0000-000000000001','EvtD','evtd','published',10,
   now()+interval '5 days','Bad/Zone');
-- Event E: draft, starts in 3h — never mailed.
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,starts_at) VALUES
  ('cccccccc-0000-0000-0000-0000000000e3','aaaaaaaa-0000-0000-0000-000000000001','EvtE','evte','draft',10,
   now()+interval '3 hours');
-- Holders of C: buyer (2 tickets → ONE mail), holder2 (1), voided (excluded).
INSERT INTO public.exos_tickets(event_id,org_id,owner_id,buyer_id,status,barcode_secret) VALUES
  ('cccccccc-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','active','s1'),
  ('cccccccc-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','active','s2'),
  ('cccccccc-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','55555555-5555-5555-5555-555555555555','55555555-5555-5555-5555-555555555555','used','s3'),
  ('cccccccc-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','66666666-6666-6666-6666-666666666666','66666666-6666-6666-6666-666666666666','voided','s4');

DO $$
DECLARE r record; n int; subj text; body text;
BEGIN
  -- C1. First cron pass: only C is due (24h window). 2 distinct non-voided holders.
  SELECT * INTO r FROM public.exos_send_event_reminders();
  ASSERT r.events_24h = 1, 'first pass events_24h=1, got '||r.events_24h;
  ASSERT r.events_2h = 0,  'first pass events_2h=0, got '||r.events_2h;
  ASSERT r.mails_queued = 2, 'first pass mails=2 (dedupe per holder, voided excluded), got '||r.mails_queued;
  SELECT count(*) INTO n FROM public.exos_mail WHERE template='event-reminder';
  ASSERT n = 2, 'event-reminder rows=2';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template='event-reminder' AND to_email='voided@x.com') = 0, 'voided holder not mailed';
  SELECT subject, html INTO subj, body FROM public.exos_mail WHERE template='event-reminder' AND to_email='buyer@x.com';
  ASSERT subj LIKE 'Reminder: Evt &lt;C&gt; — %', 'subject escaped + prefixed, got '||subj;
  ASSERT body LIKE '%Brooklyn Steel%' AND body LIKE '%Doors open at%' AND body LIKE '%(America/New_York)%', 'body carries venue/doors/tz';
  ASSERT (SELECT reminder_24h_sent_at IS NOT NULL AND reminder_2h_sent_at IS NULL
            FROM public.exos_events WHERE id='cccccccc-0000-0000-0000-0000000000e1'), '24h marked, 2h not';
  ASSERT (SELECT reminder_24h_sent_at IS NULL FROM public.exos_events WHERE id='cccccccc-0000-0000-0000-0000000000e2'), 'D (5 days out) untouched';
  ASSERT (SELECT reminder_24h_sent_at IS NULL FROM public.exos_events WHERE id='cccccccc-0000-0000-0000-0000000000e3'), 'E (draft) untouched';

  -- C2. Idempotent: a second pass sends nothing.
  SELECT * INTO r FROM public.exos_send_event_reminders();
  ASSERT r.events_24h = 0 AND r.events_2h = 0 AND r.mails_queued = 0, 'second pass is a no-op';
  RAISE NOTICE 'C1-C2 T-24h reminder + idempotency OK';

  -- C3. Time moves on: C now starts in 90 min → T-2h fires once, 24h not re-sent.
  --     (Direct starts_at edit that moves EARLIER must not reset markers.)
  UPDATE public.exos_events SET starts_at = now()+interval '90 minutes', doors_at = now()+interval '60 minutes'
   WHERE id='cccccccc-0000-0000-0000-0000000000e1';
  ASSERT (SELECT reminder_24h_sent_at IS NOT NULL FROM public.exos_events WHERE id='cccccccc-0000-0000-0000-0000000000e1'), 'earlier move keeps 24h marker';
  SELECT * INTO r FROM public.exos_send_event_reminders();
  ASSERT r.events_24h = 0 AND r.events_2h = 1 AND r.mails_queued = 2, 'T-2h pass: 1 event / 2 mails, got '||r.events_2h||'/'||r.mails_queued;
  SELECT count(*) INTO n FROM public.exos_mail WHERE template='event-reminder';
  ASSERT n = 4, 'total reminder rows=4';
  SELECT * INTO r FROM public.exos_send_event_reminders();
  ASSERT r.mails_queued = 0, 'T-2h idempotent';
  RAISE NOTICE 'C3 T-2h reminder OK';

  -- C4. Event published inside the last 2h gets ONE mail (2h pass marks 24h too).
  INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,starts_at) VALUES
    ('cccccccc-0000-0000-0000-0000000000e4','aaaaaaaa-0000-0000-0000-000000000001','EvtF','evtf','published',10,now()+interval '1 hour');
  INSERT INTO public.exos_tickets(event_id,org_id,owner_id,buyer_id,status,barcode_secret) VALUES
    ('cccccccc-0000-0000-0000-0000000000e4','aaaaaaaa-0000-0000-0000-000000000001','55555555-5555-5555-5555-555555555555','55555555-5555-5555-5555-555555555555','active','s5');
  SELECT * INTO r FROM public.exos_send_event_reminders();
  ASSERT r.events_24h = 0 AND r.events_2h = 1 AND r.mails_queued = 1, 'late-published event: one mail';
  ASSERT (SELECT reminder_24h_sent_at IS NOT NULL AND reminder_2h_sent_at IS NOT NULL FROM public.exos_events WHERE id='cccccccc-0000-0000-0000-0000000000e4'), 'both markers set';
  RAISE NOTICE 'C4 late-publish single mail OK';

  -- C5. Postpone C by 3 days → trigger clears both markers → a fresh cycle later.
  UPDATE public.exos_events SET starts_at = now()+interval '3 days' WHERE id='cccccccc-0000-0000-0000-0000000000e1';
  ASSERT (SELECT reminder_24h_sent_at IS NULL AND reminder_2h_sent_at IS NULL FROM public.exos_events WHERE id='cccccccc-0000-0000-0000-0000000000e1'), 'postpone resets markers';
  SELECT * INTO r FROM public.exos_send_event_reminders();
  ASSERT r.mails_queued = 0, 'nothing due after postpone';
  RAISE NOTICE 'C5 postpone reset OK';
END $$;

-- C6. Manual "send now": owner OK, cooldown blocks a repeat, buyer forbidden,
--     draft refused. (Bad/Zone on D must degrade to UTC, not fail.)
SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE n int; ok boolean;
BEGIN
  n := public.exos_send_event_reminder_now('cccccccc-0000-0000-0000-0000000000e1');
  ASSERT n = 2, 'manual send → 2 holders, got '||n;
  ok := false;
  BEGIN
    PERFORM public.exos_send_event_reminder_now('cccccccc-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%wait until%';
  END;
  ASSERT ok, 'second manual send within 6h blocked by cooldown';
  ok := false;
  BEGIN
    PERFORM public.exos_send_event_reminder_now('cccccccc-0000-0000-0000-0000000000e3');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%not published%';
  END;
  ASSERT ok, 'draft refused';
  -- Bad timezone degrades to UTC.
  n := public.exos_send_event_reminder_now('cccccccc-0000-0000-0000-0000000000e2');
  ASSERT n = 0, 'D has no holders → 0 mails, but no error on Bad/Zone';
  RAISE NOTICE 'C6 manual send + cooldown + tz fallback OK';
END $$;
SELECT set_config('app.uid','22222222-2222-2222-2222-222222222222',false);
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_send_event_reminder_now('cccccccc-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'buyer cannot send reminders (42501)';
  RAISE NOTICE 'C7 role gate OK';
END $$;
SELECT set_config('app.uid','',false);

-- C8. exos_invoice_counters: RLS enabled, no policies, SECDEF numbering still works.
DO $$
DECLARE nxt text;
BEGIN
  ASSERT (SELECT rowsecurity FROM pg_tables WHERE schemaname='public' AND tablename='exos_invoice_counters'), 'invoice counters RLS enabled';
  ASSERT (SELECT count(*) FROM pg_policies WHERE tablename='exos_invoice_counters') = 0, 'no policies (deny-by-default)';
  nxt := public.exos_next_invoice_number('aaaaaaaa-0000-0000-0000-000000000001');
  ASSERT nxt LIKE 'INV-%', 'numbering still works under RLS, got '||nxt;
  RAISE NOTICE 'C8 invoice-counter RLS OK';
END $$;

SELECT '*** PART C (reminders + invoice RLS) PASSED ***' AS result;
-- ============================================================================
-- PART D — ORGANIZER ANALYTICS DOCUMENT (mig 20260911130000)
--   totals · no-show only after start · tz day buckets · axes with scan-in
--   · checkin + reject rollups · role gate.
-- ============================================================================
SELECT set_config('app.uid','',false);
SELECT set_config('app.jwt','',false);
-- Event G: started 1h ago (NY tz). 5 tickets: 3 used, 1 active, 1 voided.
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold,starts_at,timezone) VALUES
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','EvtG','evtg','published',50,4,
   now()-interval '1 hour','America/New_York');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('dddddddd-0000-0000-0000-0000000000d1','dddddddd-0000-0000-0000-0000000000e1','GA',0,50,4);
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,tier_name,owner_id,buyer_id,status,barcode_secret,price_paid,channel_source,promoter_id,created_at) VALUES
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-0000000000d1','GA','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','used','g1',10,'vibepass','promoA',now()-interval '3 days'),
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-0000000000d1','GA','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','used','g2',10,'vibepass','promoA',now()-interval '3 days'),
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-0000000000d1','GA','55555555-5555-5555-5555-555555555555','55555555-5555-5555-5555-555555555555','used','g3',0,'boxoffice',NULL,now()-interval '1 day'),
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-0000000000d1','GA','55555555-5555-5555-5555-555555555555','55555555-5555-5555-5555-555555555555','active','g4',0,'boxoffice','',now()-interval '1 day'),
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-0000000000d1','GA','66666666-6666-6666-6666-666666666666','66666666-6666-6666-6666-666666666666','voided','g5',99,'vibepass','promoB',now()-interval '1 day');
INSERT INTO public.exos_event_checkins(event_id,ticket_id,org_id,scanned_by,source,verification) VALUES
  ('dddddddd-0000-0000-0000-0000000000e1',gen_random_uuid(),'aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','camera','verified'),
  ('dddddddd-0000-0000-0000-0000000000e1',gen_random_uuid(),'aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','camera','verified'),
  ('dddddddd-0000-0000-0000-0000000000e1',gen_random_uuid(),'aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','manual','manual');
INSERT INTO public.exos_scan_rejects(event_id,org_id,rejected_by,reason,source) VALUES
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','used','camera'),
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','used','camera'),
  ('dddddddd-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','wrong-event','manual');

SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE j jsonb; a jsonb;
BEGIN
  j := public.exos_event_analytics('dddddddd-0000-0000-0000-0000000000e1');
  ASSERT (j->>'sold')::int = 4, 'sold=4 (voided excluded), got '||(j->>'sold');
  ASSERT (j->>'used')::int = 3, 'used=3';
  ASSERT (j->>'unscanned')::int = 1, 'unscanned=1';
  ASSERT (j->>'voided')::int = 1, 'voided=1';
  ASSERT (j->>'revenue')::numeric = 20, 'revenue=20 (voided 99 excluded), got '||(j->>'revenue');
  ASSERT (j->>'capacity')::int = 50, 'capacity from event';
  ASSERT (j->>'event_started')::boolean, 'started';
  ASSERT (j->>'checkin_rate')::numeric = 0.75, 'checkin_rate=.75';
  ASSERT (j->>'no_show_rate')::numeric = 0.25, 'no_show_rate=.25 after start';
  ASSERT j->>'timezone' = 'America/New_York', 'tz carried';
  -- Day buckets: two distinct days (3d ago × 2, 1d ago × 2), cumulative 2 → 4.
  ASSERT jsonb_array_length(j->'sales_by_day') = 2, 'two day buckets, got '||jsonb_array_length(j->'sales_by_day');
  ASSERT (j->'sales_by_day'->0->>'sold')::int = 2 AND (j->'sales_by_day'->1->>'cumulative')::int = 4, 'daily + cumulative';
  -- Axes with scan-in.
  ASSERT jsonb_array_length(j->'by_tier') = 1 AND (j->'by_tier'->0->>'used')::int = 3, 'by_tier used=3';
  ASSERT jsonb_array_length(j->'by_promoter') = 1, 'blank/NULL/voided promoters excluded → 1 row';
  ASSERT j->'by_promoter'->0->>'promoter' = 'promoA' AND (j->'by_promoter'->0->>'used')::int = 2, 'promoA sold 2 used 2';
  SELECT x INTO a FROM jsonb_array_elements(j->'by_channel') x WHERE x->>'channel' = 'boxoffice';
  ASSERT (a->>'sold')::int = 2 AND (a->>'used')::int = 1, 'boxoffice 2 sold / 1 used';
  -- Door rollups.
  ASSERT (j->'scans'->>'total')::int = 3, 'scans total=3';
  ASSERT (j->'scans'->'by_source'->>'camera')::int = 2, 'scans by_source camera=2';
  ASSERT (j->'rejects'->>'total')::int = 3, 'rejects total=3';
  ASSERT j->'rejects'->'by_reason'->0->>'reason' = 'used' AND (j->'rejects'->'by_reason'->0->>'count')::int = 2, 'rejects by_reason sorted desc';
  RAISE NOTICE 'D1 analytics document OK';

  -- D2. Not started yet → no_show_rate is NULL, checkin_rate still reported.
  UPDATE public.exos_events SET starts_at = now()+interval '2 days', timezone = 'Not/AZone'
   WHERE id='dddddddd-0000-0000-0000-0000000000e1';
  j := public.exos_event_analytics('dddddddd-0000-0000-0000-0000000000e1');
  ASSERT NOT (j->>'event_started')::boolean AND j->'no_show_rate' = 'null'::jsonb, 'no-show NULL before start';
  ASSERT (j->>'checkin_rate')::numeric = 0.75, 'checkin_rate independent of start';
  ASSERT j->>'timezone' = 'UTC', 'bad tz degrades to UTC';
  RAISE NOTICE 'D2 pre-start + tz fallback OK';
END $$;
-- D3. Buyer (no org role) refused; unknown event refused.
SELECT set_config('app.uid','22222222-2222-2222-2222-222222222222',false);
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_event_analytics('dddddddd-0000-0000-0000-0000000000e1');
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'buyer cannot read analytics (42501)';
  ok := false;
  BEGIN
    PERFORM public.exos_event_analytics('dddddddd-0000-0000-0000-0000000000ff');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%not found%';
  END;
  ASSERT ok, 'unknown event refused';
  RAISE NOTICE 'D3 role gate OK';
END $$;
SELECT set_config('app.uid','',false);
SELECT '*** PART D (analytics) PASSED ***' AS result;
-- ============================================================================
-- PART E — SELF-SERVE RSVP RELEASE (mig 20260911131000)
--   holder release frees tier + event capacity and auto-offers the waitlist
--   · paid / used / in-transfer refused · policy off · cutoff · staff override
--   · analytics splits released out of voided.
-- ============================================================================
SELECT set_config('app.uid','',false);
SELECT set_config('app.jwt','',false);
-- Event H: free, published, starts in 3 days, 1-seat tier fully sold to buyer.
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold,starts_at,timezone) VALUES
  ('eeeeeeee-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','EvtH','evth','published',3,3,
   now()+interval '3 days','UTC');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,ticket_type) VALUES
  ('eeeeeeee-0000-0000-0000-0000000000d1','eeeeeeee-0000-0000-0000-0000000000e1','Free',0,1,1,'free'),
  ('eeeeeeee-0000-0000-0000-0000000000d2','eeeeeeee-0000-0000-0000-0000000000e1','Paid',20,5,2,'paid');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,owner_id,buyer_id,status,barcode_secret,price_paid) VALUES
  ('eeeeeeee-0000-0000-0000-0000000000a1','eeeeeeee-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-0000000000d1','Free','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','active','h1',0),
  ('eeeeeeee-0000-0000-0000-0000000000a2','eeeeeeee-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-0000000000d2','Paid','22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','active','h2',20),
  ('eeeeeeee-0000-0000-0000-0000000000a3','eeeeeeee-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-0000000000d2','Paid','55555555-5555-5555-5555-555555555555','55555555-5555-5555-5555-555555555555','active','h3',0);
-- Someone is waiting for the free tier.
INSERT INTO public.exos_waitlist(event_id,tier_id,email,status) VALUES
  ('eeeeeeee-0000-0000-0000-0000000000e1','eeeeeeee-0000-0000-0000-0000000000d1','waiter@x.com','waiting');

-- E1. Holder releases the free ticket → voided + released_at, tier 1→0,
--     event 3→2, waiter auto-offered.
SELECT set_config('app.uid','22222222-2222-2222-2222-222222222222',false);
DO $$
DECLARE j jsonb; ok boolean;
BEGIN
  j := public.exos_release_ticket('eeeeeeee-0000-0000-0000-0000000000a1');
  ASSERT j->>'by' = 'holder' AND (j->>'freed_tier')::boolean, 'holder release payload, got '||j::text;
  ASSERT (SELECT status = 'voided' AND released_at IS NOT NULL AND voided_reason = 'released-by-holder'
            FROM public.exos_tickets WHERE id='eeeeeeee-0000-0000-0000-0000000000a1'), 'ticket voided + released_at';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='eeeeeeee-0000-0000-0000-0000000000d1') = 0, 'tier sold 1→0';
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='eeeeeeee-0000-0000-0000-0000000000e1') = 2, 'event tickets_sold 3→2';
  ASSERT (SELECT status FROM public.exos_waitlist WHERE email='waiter@x.com') = 'offered', 'waiter auto-offered by the tier trigger';
  -- E2. Second release refused (not active).
  ok := false;
  BEGIN PERFORM public.exos_release_ticket('eeeeeeee-0000-0000-0000-0000000000a1');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%only an active ticket%'; END;
  ASSERT ok, 'double release refused';
  -- E3. Paid ticket refused.
  ok := false;
  BEGIN PERFORM public.exos_release_ticket('eeeeeeee-0000-0000-0000-0000000000a2');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%only free tickets%'; END;
  ASSERT ok, 'paid ticket refused';
  -- E4. Someone else's ticket refused (42501).
  ok := false;
  BEGIN PERFORM public.exos_release_ticket('eeeeeeee-0000-0000-0000-0000000000a3');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'non-owner refused';
  RAISE NOTICE 'E1-E4 holder release + refusals OK';
END $$;

-- E5. Policy off / cutoff block the HOLDER; staff still releases.
SELECT set_config('app.uid','55555555-5555-5555-5555-555555555555',false);
DO $$
DECLARE ok boolean; j jsonb;
BEGIN
  UPDATE public.exos_events SET allow_holder_release = false WHERE id='eeeeeeee-0000-0000-0000-0000000000e1';
  ok := false;
  BEGIN PERFORM public.exos_release_ticket('eeeeeeee-0000-0000-0000-0000000000a3');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%turned off self-serve release%'; END;
  ASSERT ok, 'policy off blocks holder';
  UPDATE public.exos_events SET allow_holder_release = true, release_cutoff_hours = 96 WHERE id='eeeeeeee-0000-0000-0000-0000000000e1';
  ok := false;
  BEGIN PERFORM public.exos_release_ticket('eeeeeeee-0000-0000-0000-0000000000a3');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%releases closed 96 hours%'; END;
  ASSERT ok, 'cutoff (96h > 3 days) blocks holder';
  -- In-transfer lock.
  UPDATE public.exos_events SET release_cutoff_hours = 0 WHERE id='eeeeeeee-0000-0000-0000-0000000000e1';
  UPDATE public.exos_tickets SET pending_transfer_id = gen_random_uuid() WHERE id='eeeeeeee-0000-0000-0000-0000000000a3';
  ok := false;
  BEGIN PERFORM public.exos_release_ticket('eeeeeeee-0000-0000-0000-0000000000a3');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE '%pending transfer%'; END;
  ASSERT ok, 'pending transfer blocks release';
  UPDATE public.exos_tickets SET pending_transfer_id = NULL WHERE id='eeeeeeee-0000-0000-0000-0000000000a3';
  RAISE NOTICE 'E5 policy / cutoff / transfer-lock OK';
END $$;
-- Staff (owner) releases t3 even with the cutoff back on; paid-tier free comp.
SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE j jsonb;
BEGIN
  UPDATE public.exos_events SET release_cutoff_hours = 96 WHERE id='eeeeeeee-0000-0000-0000-0000000000e1';
  j := public.exos_release_ticket('eeeeeeee-0000-0000-0000-0000000000a3');
  ASSERT j->>'by' = 'staff', 'staff override';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='eeeeeeee-0000-0000-0000-0000000000d2') = 1, 'paid tier sold 2→1';
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='eeeeeeee-0000-0000-0000-0000000000e1') = 1, 'event tickets_sold 2→1';
  -- E6. Analytics: released reported separately from voided.
  j := public.exos_event_analytics('eeeeeeee-0000-0000-0000-0000000000e1');
  ASSERT (j->>'released')::int = 2 AND (j->>'voided')::int = 0 AND (j->>'sold')::int = 1,
    'analytics released=2 voided=0 sold=1, got '||j::text;
  RAISE NOTICE 'E6 staff release + analytics split OK';
END $$;
SELECT set_config('app.uid','',false);
SELECT '*** PART E (rsvp release) PASSED ***' AS result;
-- ============================================================================
-- PART F — BULK COMP ISSUANCE + ORG COMP BUDGET (mig 20260911132000)
--   account → issued + mail · no account → caller-held + pending transfer +
--   mail · invalid / dedupe / self · per-row capacity · whole-batch budget gate
--   · usage + budget setter role gates.
-- ============================================================================
SELECT set_config('app.uid','',false);
SELECT set_config('app.jwt','',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold,starts_at,created_by) VALUES
  ('ffffffff-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','Evt <Comp>','evtcomp','published',6,0,
   now()+interval '10 days','11111111-1111-1111-1111-111111111111');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('ffffffff-0000-0000-0000-0000000000d1','ffffffff-0000-0000-0000-0000000000e1','VIP',100,3,0);

SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
SELECT set_config('app.jwt','{"email":"owner@s4kent.com"}',false);
DO $$
DECLARE r record; n int; v_tr uuid;
BEGIN
  -- F1. Mixed list: account holder, stranger, junk, duplicate, self.
  CREATE TEMP TABLE f_out ON COMMIT DROP AS
  SELECT * FROM public.exos_issue_comp_batch('ffffffff-0000-0000-0000-0000000000e1','ffffffff-0000-0000-0000-0000000000d1',
    ARRAY['Buyer@X.com','  new.person@x.com ','nope','buyer@x.com','owner@s4kent.com'], 1, 'press');
  SELECT count(*) INTO n FROM f_out; ASSERT n = 4, 'dedupe → 4 result rows, got '||n;
  SELECT * INTO r FROM f_out WHERE email='buyer@x.com';
  ASSERT r.outcome = 'issued' AND array_length(r.ticket_ids,1) = 1, 'account holder issued';
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = r.ticket_ids[1]) = '22222222-2222-2222-2222-222222222222', 'owned by recipient';
  ASSERT (SELECT channel_source='comp' AND price_paid=0 AND promoter_id='press' AND order_ref LIKE 'comp:%' FROM public.exos_tickets WHERE id = r.ticket_ids[1]), 'comp ticket shape';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template='ticket-issued' AND to_email='buyer@x.com' AND html LIKE '%Evt &lt;Comp&gt;%') = 1, 'ticket-issued mail, escaped';
  SELECT * INTO r FROM f_out WHERE email='new.person@x.com';
  ASSERT r.outcome = 'invited', 'stranger invited, got '||r.outcome;
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = r.ticket_ids[1]) = '11111111-1111-1111-1111-111111111111', 'stranger ticket parked on caller';
  SELECT pending_transfer_id INTO v_tr FROM public.exos_tickets WHERE id = r.ticket_ids[1];
  ASSERT v_tr IS NOT NULL, 'pending transfer lock set';
  ASSERT (SELECT receiver_email='new.person@x.com' AND status='pending' AND sender_id='11111111-1111-1111-1111-111111111111' FROM public.exos_transfers WHERE id = v_tr), 'transfer row addressed to the stranger';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template='transfer-initiated' AND to_email='new.person@x.com') = 1, 'transfer-initiated mail';
  ASSERT (SELECT outcome FROM f_out WHERE email='nope') = 'invalid', 'junk invalid';
  ASSERT (SELECT outcome FROM f_out WHERE email='owner@s4kent.com') = 'invalid', 'self invalid';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='ffffffff-0000-0000-0000-0000000000d1') = 2, 'tier sold 2';
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='ffffffff-0000-0000-0000-0000000000e1') = 2, 'event sold 2';
  ASSERT public.exos_org_comp_usage('aaaaaaaa-0000-0000-0000-000000000001') >= 2, 'usage counts comps';
  RAISE NOTICE 'F1 mixed batch OK';
  DROP TABLE f_out;

  -- F2. Per-row capacity: tier has 1 seat left; 2 recipients → 1 issued, 1 sold-out.
  CREATE TEMP TABLE f_out ON COMMIT DROP AS
  SELECT * FROM public.exos_issue_comp_batch('ffffffff-0000-0000-0000-0000000000e1','ffffffff-0000-0000-0000-0000000000d1',
    ARRAY['c1@x.com','c2@x.com'], 1, NULL);
  ASSERT (SELECT count(*) FROM f_out WHERE outcome='invited') = 1 AND (SELECT count(*) FROM f_out WHERE outcome='sold-out') = 1, 'one invited, one sold-out';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='ffffffff-0000-0000-0000-0000000000d1') = 3, 'tier at cap';
  DROP TABLE f_out;
  RAISE NOTICE 'F2 per-row capacity OK';
END $$;

-- F3. Budget: owner sets 4 (usage in this org ≥ 3 comps from F1/F2 + earlier
--     boxoffice rows) → a 2-seat batch is refused WHOLE, nothing issued.
DO $$
DECLARE ok boolean := false; before int; n int; usage int;
BEGIN
  usage := public.exos_org_comp_usage('aaaaaaaa-0000-0000-0000-000000000001');
  PERFORM public.exos_set_org_comp_budget('aaaaaaaa-0000-0000-0000-000000000001', usage + 1);
  SELECT count(*) INTO before FROM public.exos_tickets WHERE event_id='ffffffff-0000-0000-0000-0000000000e1';
  BEGIN
    PERFORM public.exos_issue_comp_batch('ffffffff-0000-0000-0000-0000000000e1', NULL, ARRAY['d1@x.com','d2@x.com'], 1, NULL);
  EXCEPTION WHEN check_violation THEN ok := SQLERRM LIKE '%comp budget exceeded%';
  END;
  ASSERT ok, 'over-budget batch refused (23514)';
  SELECT count(*) INTO n FROM public.exos_tickets WHERE event_id='ffffffff-0000-0000-0000-0000000000e1';
  ASSERT n = before, 'nothing issued on refusal';
  -- Exactly within budget (1 left) → allowed, no tier (house cap only).
  PERFORM public.exos_issue_comp_batch('ffffffff-0000-0000-0000-0000000000e1', NULL, ARRAY['d1@x.com'], 1, NULL);
  ASSERT public.exos_org_comp_usage('aaaaaaaa-0000-0000-0000-000000000001') = usage + 1, 'usage advanced to the budget';
  -- Clear the cap (NULL) → unlimited again.
  PERFORM public.exos_set_org_comp_budget('aaaaaaaa-0000-0000-0000-000000000001', NULL);
  PERFORM public.exos_issue_comp_batch('ffffffff-0000-0000-0000-0000000000e1', NULL, ARRAY['d2@x.com'], 1, NULL);
  RAISE NOTICE 'F3 budget gate OK';
END $$;
-- F4. Role gates: buyer cannot issue, read usage, or set the budget.
SELECT set_config('app.uid','22222222-2222-2222-2222-222222222222',false);
SELECT set_config('app.jwt','',false);
DO $$
DECLARE ok boolean;
BEGIN
  ok := false;
  BEGIN PERFORM public.exos_issue_comp_batch('ffffffff-0000-0000-0000-0000000000e1', NULL, ARRAY['z@x.com'], 1, NULL);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'buyer cannot issue comps';
  ok := false;
  BEGIN PERFORM public.exos_org_comp_usage('aaaaaaaa-0000-0000-0000-000000000001');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'buyer cannot read usage';
  ok := false;
  BEGIN PERFORM public.exos_set_org_comp_budget('aaaaaaaa-0000-0000-0000-000000000001', 1);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'buyer cannot set budget';
  RAISE NOTICE 'F4 role gates OK';
END $$;
SELECT set_config('app.uid','',false);
SELECT '*** PART F (comp batch + budget) PASSED ***' AS result;
-- ============================================================================
-- PART G — RECURRING / TIMED-ENTRY SERIES (mig 20260911133000)
--   clone template + tiers per occurrence · deltas preserved · occurs_at_local
--   recomputed · counters/markers cleared · slug suffixed · extend an existing
--   series · dedupe + template-start skip · status override · role gate.
-- ============================================================================
SELECT set_config('app.uid','',false);
SELECT set_config('app.jwt','',false);
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold,starts_at,doors_at,timezone,venue_name,reminder_24h_sent_at) VALUES
  ('99999999-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','Friday Night','friday-night','published',100,7,
   '2026-10-30 20:00-04'::timestamptz, '2026-10-30 19:00-04'::timestamptz, 'America/New_York', 'Brooklyn Steel', now());
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,ticket_type,sort_order) VALUES
  ('99999999-0000-0000-0000-0000000000d1','99999999-0000-0000-0000-0000000000e1','GA',0,80,7,'free',0),
  ('99999999-0000-0000-0000-0000000000d2','99999999-0000-0000-0000-0000000000e1','VIP',40,20,0,'paid',1);

-- G0. occurs_at_local helper: DST-correct offset, bad tz → NULL.
DO $$
BEGIN
  ASSERT public.exos_occurs_at_local('2026-10-30 20:00-04'::timestamptz,'America/New_York') = '2026-10-30T20:00:00-04:00', 'EDT offset';
  ASSERT public.exos_occurs_at_local('2026-11-06 20:00-05'::timestamptz,'America/New_York') = '2026-11-06T20:00:00-05:00', 'EST offset after fall-back';
  ASSERT public.exos_occurs_at_local('2026-11-06 20:00+00'::timestamptz,'Asia/Kolkata') = '2026-11-07T01:30:00+05:30', 'half-hour zone';
  ASSERT public.exos_occurs_at_local(now(),'Not/AZone') IS NULL, 'bad tz → NULL';
  RAISE NOTICE 'G0 occurs_at_local OK';
END $$;

SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE r record; n int; v_series uuid; v_new uuid; v_doors timestamptz; v_local text;
BEGIN
  -- G1. Weekly × 3 across the DST change (wall-clock 20:00 stays), template
  --     start included in the array + a duplicate → both dropped.
  CREATE TEMP TABLE g_out ON COMMIT DROP AS
  SELECT * FROM public.exos_create_event_series('99999999-0000-0000-0000-0000000000e1',
    ARRAY['2026-10-30 20:00-04','2026-11-06 20:00-05','2026-11-06 20:00-05','2026-11-13 20:00-05','2026-11-20 20:00-05']::timestamptz[],
    'recurring', 'Friday Nights', '{"freq":"weekly","count":3}'::jsonb, NULL);
  SELECT count(*) INTO n FROM g_out; ASSERT n = 3, 'three new occurrences (template + dup skipped), got '||n;
  ASSERT (SELECT array_agg(series_index ORDER BY series_index) FROM g_out) = ARRAY[1,2,3], 'indexes 1..3';
  SELECT series_id INTO v_series FROM public.exos_events WHERE id='99999999-0000-0000-0000-0000000000e1';
  ASSERT v_series IS NOT NULL AND (SELECT series_index FROM public.exos_events WHERE id='99999999-0000-0000-0000-0000000000e1') = 0, 'template is member 0';
  ASSERT (SELECT name='Friday Nights' AND kind='recurring' AND template_event_id='99999999-0000-0000-0000-0000000000e1' AND timezone='America/New_York'
            FROM public.exos_event_series WHERE id=v_series), 'series row';
  SELECT event_id INTO v_new FROM g_out WHERE series_index = 1;
  SELECT doors_at, occurs_at_local INTO v_doors, v_local FROM public.exos_events WHERE id = v_new;
  ASSERT v_doors = '2026-11-06 19:00-05'::timestamptz, 'doors delta (-1h) preserved, got '||v_doors;
  ASSERT v_local = '2026-11-06T20:00:00-05:00', 'occurs_at_local recomputed in tz, got '||v_local;
  ASSERT (SELECT name='Friday Night' AND status='published' AND venue_name='Brooklyn Steel' AND total_tickets=100
             AND tickets_sold=0 AND reminder_24h_sent_at IS NULL AND slug='friday-night-20261106-2000'
             AND series_id=v_series AND created_by='11111111-1111-1111-1111-111111111111'
            FROM public.exos_events WHERE id=v_new), 'clone carries template fields, clears counters/markers, suffixes slug';
  -- Tiers cloned with sold = 0, both of them, order kept.
  ASSERT (SELECT count(*) FROM public.exos_ticket_tiers WHERE event_id=v_new) = 2, 'two tiers cloned';
  ASSERT (SELECT array_agg(name ORDER BY sort_order) FROM public.exos_ticket_tiers WHERE event_id=v_new) = ARRAY['GA','VIP'], 'tier names';
  ASSERT (SELECT sum(sold) FROM public.exos_ticket_tiers WHERE event_id=v_new) = 0, 'clone tiers unsold';
  ASSERT (SELECT capacity FROM public.exos_ticket_tiers WHERE event_id=v_new AND name='GA') = 80, 'tier capacity copied';
  -- Template untouched.
  ASSERT (SELECT tickets_sold=7 AND slug='friday-night' FROM public.exos_events WHERE id='99999999-0000-0000-0000-0000000000e1'), 'template unchanged';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='99999999-0000-0000-0000-0000000000d1') = 7, 'template tier unchanged';
  DROP TABLE g_out;
  RAISE NOTICE 'G1 create series OK';

  -- G2. Extend: same template again → same series, indexes continue at 4;
  --     p_publish=false → drafts.
  CREATE TEMP TABLE g_out ON COMMIT DROP AS
  SELECT * FROM public.exos_create_event_series('99999999-0000-0000-0000-0000000000e1',
    ARRAY['2026-11-27 20:00-05']::timestamptz[], 'recurring', NULL, NULL, false);
  ASSERT (SELECT series_index FROM g_out) = 4, 'extend continues index at 4';
  SELECT event_id INTO v_new FROM g_out;
  ASSERT (SELECT series_id=v_series AND status='draft' FROM public.exos_events WHERE id=v_new), 'same series, draft status';
  ASSERT (SELECT count(*) FROM public.exos_event_series WHERE org_id='aaaaaaaa-0000-0000-0000-000000000001' AND name='Friday Nights') = 1, 'no second series row';
  ASSERT (SELECT count(*) FROM public.exos_events WHERE series_id=v_series) = 5, '5 members';
  DROP TABLE g_out;
  RAISE NOTICE 'G2 extend series OK';

  -- G3. Timed-entry kind on a fresh template; nothing new → refused.
  BEGIN
    PERFORM public.exos_create_event_series('99999999-0000-0000-0000-0000000000e1', ARRAY['2026-10-30 20:00-04']::timestamptz[], 'recurring', NULL, NULL, NULL);
    ASSERT false, 'template-only array should be refused';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE '%no new occurrences%', 'no new occurrences message, got '||SQLERRM;
  END;
  BEGIN
    PERFORM public.exos_create_event_series('99999999-0000-0000-0000-0000000000e1', ARRAY['2027-01-01 20:00-05']::timestamptz[], 'monthly', NULL, NULL, NULL);
    ASSERT false, 'bad kind should be refused';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE '%kind must be%', 'kind check';
  END;
  RAISE NOTICE 'G3 refusals OK';
END $$;
-- G4. Buyer cannot create a series (42501).
SELECT set_config('app.uid','22222222-2222-2222-2222-222222222222',false);
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_create_event_series('99999999-0000-0000-0000-0000000000e1', ARRAY['2027-01-01 20:00-05']::timestamptz[], 'recurring', NULL, NULL, NULL);
  EXCEPTION WHEN insufficient_privilege THEN ok := true;
  END;
  ASSERT ok, 'buyer refused';
  ASSERT (SELECT rowsecurity FROM pg_tables WHERE schemaname='public' AND tablename='exos_event_series'), 'series RLS on';
  RAISE NOTICE 'G4 role gate OK';
END $$;
SELECT set_config('app.uid','',false);
SELECT '*** PART G (event series) PASSED ***' AS result;
SELECT '*** ALL EXOS TESTS PASSED ***' AS result;
