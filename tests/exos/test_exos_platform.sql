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
  UPDATE public.exos_checkout_sessions SET status='fulfilled' WHERE session_id='B-s2';
  SELECT status INTO st FROM public.exos_waitlist WHERE email='buyer2@x.com';
  ASSERT st='converted', 'waitlist converted on redeem, got '||st;
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE id=vid)=1, 'voucher consumed';
  SELECT number INTO inv2 FROM public.exos_invoices WHERE session_id='B-s2';
  ASSERT inv2='INV-000002', 'second invoice sequential, got '||coalesce(inv2,'null');
  RAISE NOTICE 'B step 5: voucher redeem → convert + consume + invoice #2 OK';
END $$;

SELECT '*** PART B (end-to-end platform) PASSED ***' AS result;
SELECT '*** ALL EXOS TESTS PASSED ***' AS result;
