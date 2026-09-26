-- ============================================================================
-- Promoter commissions (mig 20260926020000). Self-contained: own fixtures
-- (0c0c… ids, org slug pc-org), everything rolled back.
--   bash: createdb -T growth_base pc_run; psql -d pc_run -f <migration>;
--         psql -d pc_run -v ON_ERROR_STOP=1 -f tests/exos/test_promoter_commissions.sql
-- Users: owner …a1, manager …a2, finance …a3, stranger …a4, buyer …a5.
-- Promoters: A = pc-a (10%), B = pc-b ($1.50 flat); A has 20% + $0.50 on E2.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('0c0c0000-0000-0000-0000-0000000000a1','pcowner@x.com',now()),
  ('0c0c0000-0000-0000-0000-0000000000a2','pcmanager@x.com',now()),
  ('0c0c0000-0000-0000-0000-0000000000a3','pcfinance@x.com',now()),
  ('0c0c0000-0000-0000-0000-0000000000a4','pcstranger@x.com',now()),
  ('0c0c0000-0000-0000-0000-0000000000a5','pcbuyer@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('0c0c0000-0000-0000-0000-000000000001','PC Org','pc-org','0c0c0000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a1','owner'),
  ('0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a2','manager'),
  ('0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a3','finance');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at,currency) VALUES
  ('0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-000000000001','PC Night One','published',now()+interval '7 days','usd'),
  ('0c0c0000-0000-0000-0000-0000000000e2','0c0c0000-0000-0000-0000-000000000001','PC Night Two','published',now()+interval '14 days','usd');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('0c0c0000-0000-0000-0000-0000000000d1','0c0c0000-0000-0000-0000-0000000000e1','GA',20,0,0),
  ('0c0c0000-0000-0000-0000-0000000000d2','0c0c0000-0000-0000-0000-0000000000e2','GA',30,0,0);

-- Promoters + terms (owner).
SELECT set_config('app.uid','0c0c0000-0000-0000-0000-0000000000a1',false);
SELECT public.exos_upsert_promoter('0c0c0000-0000-0000-0000-000000000001','pc-a','Promoter A');
SELECT public.exos_upsert_promoter('0c0c0000-0000-0000-0000-000000000001','pc-b','Promoter B');
DO $$
DECLARE a uuid; b uuid;
BEGIN
  SELECT id INTO a FROM public.exos_promoters WHERE code='pc-a' AND org_id='0c0c0000-0000-0000-0000-000000000001';
  SELECT id INTO b FROM public.exos_promoters WHERE code='pc-b' AND org_id='0c0c0000-0000-0000-0000-000000000001';
  PERFORM public.exos_set_promoter_terms(a, 1000, 0);
  PERFORM public.exos_set_promoter_terms(b, 0, 150);
  PERFORM public.exos_set_promoter_terms(a, 2000, 50, '0c0c0000-0000-0000-0000-0000000000e2');
  PERFORM set_config('test.pa', a::text, false);
  PERFORM set_config('test.pb', b::text, false);
END $$;
SELECT set_config('app.uid','',false);

-- Paid orders (fulfilled as the webhook would).
--   s1: A, E1, 2 x $20 + 10% exclusive tax: amount 4400, tax 400 -> base 2000 each.
--   s2: B, E1, 1 x $15, no tax.
--   s3: A, E2, 1 x $30 (override applies).
--   s4: A, E1, 1 x $20 + one $5 add-on, no tax -> base 2000.
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,tax_cents,status,promoter_id,addons) VALUES
  ('pc-s1','0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-0000000000d1','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','pcbuyer@x.com',2,4400,400,'pending','pc-a',NULL),
  ('pc-s2','0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-0000000000d1','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','pcbuyer@x.com',1,1500,NULL,'pending','pc-b',NULL),
  ('pc-s3','0c0c0000-0000-0000-0000-0000000000e2','0c0c0000-0000-0000-0000-0000000000d2','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','pcbuyer@x.com',1,3000,NULL,'pending','pc-a',NULL),
  ('pc-s4','0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-0000000000d1','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','pcbuyer@x.com',1,2500,NULL,'pending','pc-a',
   '[{"addon_id":null,"quantity":1,"unit_price_cents":500,"name":"Drink"}]');
SELECT public.exos_fulfill_checkout('pc-s1');
SELECT public.exos_fulfill_checkout('pc-s2');
SELECT public.exos_fulfill_checkout('pc-s3');
SELECT public.exos_fulfill_checkout('pc-s4');

-- C1. Percent: 10% of the net-of-tax base.
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id
           WHERE t.order_ref='pc-s1' AND c.base_cents=2000 AND c.gross_cents=2200 AND c.commission_cents=200
             AND c.status='accrued' AND c.terms_source='promoter') = 2, 'C1: two rows, base 2000, 10% = 200';
  ASSERT (SELECT c.base_cents FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id
           WHERE t.order_ref='pc-s4') = 2000, 'C1: add-ons are not part of the base';
  RAISE NOTICE 'OK  C1 percent commission on the base net of tax and add-ons';
END $$;

-- C2. Flat per ticket, capped at the base.
DO $$
BEGIN
  ASSERT (SELECT c.commission_cents FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id
           WHERE t.order_ref='pc-s2') = 150, 'C2: flat $1.50';
  ASSERT public.exos_pc_commission_cents(100, 0, 150) = 100, 'C2: flat capped at base';
  ASSERT public.exos_pc_commission_cents(999, 1000, 0) = 99, 'C2: floor to the cent';
  ASSERT public.exos_pc_commission_cents(1000, 1250, 25) = 150, 'C2: percent + flat';
  ASSERT public.exos_pc_commission_cents(0, 1000, 150) = 0, 'C2: zero base';
  RAISE NOTICE 'OK  C2 flat commission, cap, floor';
END $$;

-- C3. The per-event override wins over the promoter default.
DO $$
BEGIN
  ASSERT (SELECT c.commission_cents || '/' || c.terms_source FROM public.exos_promoter_commissions c
            JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s3') = '650/event',
         'C3: 20% of 3000 + 50 = 650 from the event override';
  RAISE NOTICE 'OK  C3 per-event override wins';
END $$;

-- C4. Comps and free tickets earn nothing.
DO $$
BEGIN
  INSERT INTO public.exos_tickets(event_id,org_id,buyer_id,owner_id,status,price_paid,order_ref,channel_source,promoter_id,barcode_secret) VALUES
    ('0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','0c0c0000-0000-0000-0000-0000000000a5','active',0,'comp:pc','comp','pc-a','s'),
    ('0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','0c0c0000-0000-0000-0000-0000000000a5','active',25,'comp:pc2','comp','pc-a','s'),
    ('0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','0c0c0000-0000-0000-0000-0000000000a5','active',0,'pc-free','vibepass','pc-a','s');
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id
           WHERE t.order_ref IN ('comp:pc','comp:pc2','pc-free')) = 0, 'C4: no commission on comps / free';
  RAISE NOTICE 'OK  C4 comp and free tickets: no commission';
END $$;

-- C5. Replaying fulfillment (or the accrual) never double-accrues.
DO $$
DECLARE n int; tid uuid;
BEGIN
  PERFORM public.exos_fulfill_checkout('pc-s1');
  PERFORM public.exos_fulfill_checkout('pc-s1');
  SELECT id INTO tid FROM public.exos_tickets WHERE order_ref='pc-s1' LIMIT 1;
  ASSERT NOT public.exos_pc_accrue_ticket(tid), 'C5: second accrual is a no-op';
  SELECT count(*) INTO n FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s1';
  ASSERT n = 2, 'C5: still two rows, got ' || n;
  RAISE NOTICE 'OK  C5 double fulfillment does not double-accrue';
END $$;

-- C6. Void reverses; a partial refund that leaves the ticket valid doesn't.
DO $$
DECLARE tid uuid;
BEGIN
  SELECT id INTO tid FROM public.exos_tickets WHERE order_ref='pc-s4';
  UPDATE public.exos_tickets SET status='voided', voided_at=now(), voided_reason='staff void' WHERE id=tid;
  ASSERT (SELECT status || '/' || reversed_reason FROM public.exos_promoter_commissions WHERE ticket_id=tid) = 'reversed/staff void',
         'C6: void reverses the row';
  PERFORM public.exos_record_refund('pc-s2','re_pc_partial',500,'succeeded');
  ASSERT (SELECT c.status FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id
           WHERE t.order_ref='pc-s2') = 'accrued', 'C6: partial refund leaves the commission';
  RAISE NOTICE 'OK  C6 void reverses; partial refund does not';
END $$;

-- C7. A refund (order voided) reverses.
DO $$
BEGIN
  PERFORM public.exos_refund_checkout('pc-s3', 'refunded');
  ASSERT (SELECT c.status FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id
           WHERE t.order_ref='pc-s3') = 'reversed', 'C7: refund reverses';
  RAISE NOTICE 'OK  C7 refund reverses';
END $$;

-- C8. Non-staff can't set terms or record payouts; finance reads only.
DO $$
DECLARE a uuid := current_setting('test.pa')::uuid; ok boolean; u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['0c0c0000-0000-0000-0000-0000000000a4','0c0c0000-0000-0000-0000-0000000000a3'] LOOP
    PERFORM set_config('app.uid', u, false);
    ok := false;
    BEGIN PERFORM public.exos_set_promoter_terms(a, 9000, 0);
    EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
    ASSERT ok, 'C8: ' || u || ' set terms';
    ok := false;
    BEGIN PERFORM public.exos_record_promoter_payout(a, ARRAY(SELECT id FROM public.exos_promoter_commissions WHERE promoter_id=a AND status='accrued'), 400, 'Venmo');
    EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
    ASSERT ok, 'C8: ' || u || ' recorded a payout';
  END LOOP;
  -- finance reads the org view; the stranger can't.
  PERFORM set_config('app.uid','0c0c0000-0000-0000-0000-0000000000a3',false);
  ASSERT (SELECT owed_cents FROM public.exos_org_promoter_commissions('0c0c0000-0000-0000-0000-000000000001') WHERE code='pc-a') = 400,
         'C8: finance sees A owed 400';
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions WHERE promoter_id=a) = 4, 'C8: finance reads rows via RLS';
  PERFORM set_config('app.uid','0c0c0000-0000-0000-0000-0000000000a4',false);
  ok := false;
  BEGIN PERFORM * FROM public.exos_org_promoter_commissions('0c0c0000-0000-0000-0000-000000000001');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'C8: stranger read the org view';
  -- the manager may write.
  PERFORM set_config('app.uid','0c0c0000-0000-0000-0000-0000000000a2',false);
  PERFORM public.exos_set_promoter_terms(a, 1000, 0);
  PERFORM set_config('app.uid','',false);
  RAISE NOTICE 'OK  C8 only owner / manager write; finance reads';
END $$;

-- C8b. RLS: a signed-in stranger sees no rows, and nobody writes directly.
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid','0c0c0000-0000-0000-0000-0000000000a4',false);
DO $$
DECLARE ok boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions WHERE org_id='0c0c0000-0000-0000-0000-000000000001') = 0, 'C8b: stranger sees no rows';
  BEGIN
    UPDATE public.exos_promoter_commissions SET status='paid';
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'C8b: direct write allowed';
  ok := false;
  BEGIN PERFORM public.exos_pc_accrue_ticket(gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'C8b: authenticated called the internal accrual';
  RAISE NOTICE 'OK  C8b RLS read scope, no direct writes';
END $$;
RESET ROLE;
SELECT set_config('app.uid','',false);

-- C9. Payouts: mark rows paid; refuse reversed / already-paid rows and a
--     wrong amount; a later refund on a paid row is netted from the next one.
SELECT set_config('app.uid','0c0c0000-0000-0000-0000-0000000000a1',false);
DO $$
DECLARE a uuid := current_setting('test.pa')::uuid; s1 uuid[]; rev uuid; po uuid; ok boolean; s5 uuid[]; po2 uuid;
BEGIN
  SELECT array_agg(c.id) INTO s1 FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s1';
  SELECT c.id INTO rev FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s3';
  ok := false;
  BEGIN PERFORM public.exos_record_promoter_payout(a, s1 || rev, 400, 'Venmo');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'C9: a reversed row was accepted';
  ok := false;
  BEGIN PERFORM public.exos_record_promoter_payout(a, s1, 399, 'Venmo');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'C9: a wrong amount was accepted';
  ok := false;
  BEGIN PERFORM public.exos_record_promoter_payout(a, ARRAY(SELECT c.id FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s2'), 150, 'Venmo');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'C9: B''s row paid under A';

  po := public.exos_record_promoter_payout(a, s1, 400, 'Venmo', 'first week', '2026-09-20');
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions WHERE id = ANY(s1) AND status='paid' AND payout_id=po) = 2, 'C9: rows paid';
  ASSERT (SELECT amount_cents || '/' || method FROM public.exos_promoter_payouts WHERE id=po) = '400/Venmo', 'C9: payout recorded';
  ok := false;
  BEGIN PERFORM public.exos_record_promoter_payout(a, s1, 400, 'Venmo');
  EXCEPTION WHEN invalid_parameter_value THEN ok := true; END;
  ASSERT ok, 'C9: already-paid rows paid twice';

  -- Clawback: one paid ticket is refunded afterwards.
  UPDATE public.exos_tickets SET status='voided', voided_at=now(), voided_reason='refunded'
   WHERE id = (SELECT ticket_id FROM public.exos_promoter_commissions WHERE id = s1[1]);
  ASSERT (SELECT owed_cents || '/' || clawback_cents || '/' || paid_cents FROM public.exos_org_promoter_commissions('0c0c0000-0000-0000-0000-000000000001') WHERE code='pc-a')
         = '-200/200/200', 'C9: clawback shows as negative owed';
  -- Next sale (200) nets the clawback out: payout of 0.
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,promoter_id)
  VALUES ('pc-s5','0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-0000000000d1','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','pcbuyer@x.com',2,4000,'pending','pc-a');
  PERFORM public.exos_fulfill_checkout('pc-s5');
  SELECT array_agg(c.id) INTO s5 FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s5';
  po2 := public.exos_record_promoter_payout(a, s5, 200, 'Cash');
  ASSERT (SELECT commission_cents || '/' || clawback_cents FROM public.exos_promoter_payouts WHERE id=po2) = '400/200', 'C9: clawback netted';
  ASSERT (SELECT owed_cents FROM public.exos_org_promoter_commissions('0c0c0000-0000-0000-0000-000000000001') WHERE code='pc-a') = 0, 'C9: settled';
  RAISE NOTICE 'OK  C9 payouts: rows paid, reversed / paid rows refused, clawback netted';
END $$;
SELECT set_config('app.uid','',false);

-- C10. Portal: each token sees only its own promoter's earnings, no buyer data.
DO $$
DECLARE ta uuid; tb uuid; ea jsonb; eb jsonb;
BEGIN
  SELECT kit_token INTO ta FROM public.exos_promoters WHERE id = current_setting('test.pa')::uuid;
  SELECT kit_token INTO tb FROM public.exos_promoters WHERE id = current_setting('test.pb')::uuid;
  ea := public.exos_promoter_earnings(ta);
  eb := public.exos_promoter_earnings(tb);
  ASSERT ea->'promoter'->>'code' = 'pc-a' AND eb->'promoter'->>'code' = 'pc-b', 'C10: right promoter';
  ASSERT (eb->'totals'->0->>'owed_cents')::int = 150 AND (eb->'totals'->0->>'tickets')::int = 1, 'C10: B sees only B: ' || (eb->'totals')::text;
  ASSERT (ea->'totals'->0->>'paid_cents')::int = 600, 'C10: A paid rows = 600, got ' || (ea->'totals')::text;
  ASSERT jsonb_array_length(ea->'payouts') = 2 AND jsonb_array_length(eb->'payouts') = 0, 'C10: payouts scoped';
  ASSERT (SELECT (e->>'rate_bps')::int FROM jsonb_array_elements(ea->'events') e WHERE e->>'event_id'='0c0c0000-0000-0000-0000-0000000000e2') = 2000,
         'C10: per-event terms shown';
  ASSERT position('pcbuyer' in ea::text) = 0 AND position('pc-s1' in ea::text) = 0 AND position('first week' in ea::text) = 0
         AND NOT (ea::text ~ (SELECT string_agg(ticket_id::text, '|') FROM public.exos_promoter_commissions WHERE ticket_id IS NOT NULL)),
         'C10: no buyer email, order ref, ticket id or payout note';
  ASSERT public.exos_promoter_earnings(gen_random_uuid()) IS NULL, 'C10: wrong token sees nothing';
  RAISE NOTICE 'OK  C10 portal earnings scoped to the token';
END $$;

-- C11. Anon: only the token-gated portal read.
SET LOCAL ROLE anon;
DO $$
DECLARE ok boolean;
BEGIN
  ok := false;
  BEGIN PERFORM public.exos_set_promoter_terms(current_setting('test.pa')::uuid, 9000, 0);
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'C11: anon set terms';
  ok := false;
  BEGIN PERFORM public.exos_record_promoter_payout(current_setting('test.pa')::uuid, ARRAY[gen_random_uuid()], 0, 'x');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'C11: anon recorded a payout';
  ok := false;
  BEGIN PERFORM * FROM public.exos_org_promoter_commissions('0c0c0000-0000-0000-0000-000000000001');
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'C11: anon read the org view';
  ok := false;
  BEGIN PERFORM count(*) FROM public.exos_promoter_commissions;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  ASSERT ok, 'C11: anon read the ledger';
  ASSERT public.exos_promoter_earnings(gen_random_uuid()) IS NULL, 'C11: anon may call the portal read';
  RAISE NOTICE 'OK  C11 anon locked out';
END $$;
RESET ROLE;

-- C12. Re-pricing accrued rows; paid rows keep their terms.
SELECT set_config('app.uid','0c0c0000-0000-0000-0000-0000000000a1',false);
DO $$
DECLARE b uuid := current_setting('test.pb')::uuid; n int;
BEGIN
  n := public.exos_set_promoter_terms(b, 1000, 0, NULL, true);
  ASSERT n = 1, 'C12: one accrued row repriced, got ' || n;
  ASSERT (SELECT c.commission_cents FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s2') = 150,
         'C12: 10% of 1500';
  n := public.exos_set_promoter_terms(current_setting('test.pa')::uuid, 5000, 0, NULL, true);
  ASSERT n = 0, 'C12: A has no accrued rows left, got ' || n;
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions WHERE promoter_id=current_setting('test.pa')::uuid AND rate_bps=5000) = 0,
         'C12: paid / reversed rows untouched';
  -- override removal
  PERFORM public.exos_set_promoter_terms(current_setting('test.pa')::uuid, NULL, NULL, '0c0c0000-0000-0000-0000-0000000000e2');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_promoter_event_terms WHERE promoter_id=current_setting('test.pa')::uuid), 'C12: override removed';
  RAISE NOTICE 'OK  C12 re-price accrued only; override removal';
END $$;

-- C13. A promoter registered after sales picks them up (backfill).
DO $$
BEGIN
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,promoter_id)
  VALUES ('pc-s6','0c0c0000-0000-0000-0000-0000000000e1','0c0c0000-0000-0000-0000-0000000000d1','0c0c0000-0000-0000-0000-000000000001','0c0c0000-0000-0000-0000-0000000000a5','pcbuyer@x.com',1,2000,'pending','pc-late');
  PERFORM public.exos_fulfill_checkout('pc-s6');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s6'), 'C13: no record, no row yet';
  PERFORM public.exos_upsert_promoter('0c0c0000-0000-0000-0000-000000000001','pc-late','Late');
  ASSERT (SELECT count(*) FROM public.exos_promoter_commissions c JOIN public.exos_tickets t ON t.id=c.ticket_id WHERE t.order_ref='pc-s6') = 1, 'C13: backfilled';
  RAISE NOTICE 'OK  C13 late registration backfills';
END $$;
SELECT set_config('app.uid','',false);

ROLLBACK;
