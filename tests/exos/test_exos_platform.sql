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
  ASSERT public.exos_leave_waitlist((SELECT id FROM public.exos_waitlist WHERE email='b@x.com'),'b@x.com'), 'leave';
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

  -- Enable server-side test mode → gate lifted.
  UPDATE public.exos_events SET checkin_test_mode=true WHERE id='aaaaaaaa-0000-0000-0000-0000000000e9';

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
SELECT '*** ALL EXOS TESTS PASSED ***' AS result;
