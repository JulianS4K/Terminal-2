-- ============================================================================
-- P0 regression tests (2026-09-24). Runs after test_exos_platform.sql in the
-- same DB (see run_p0.sh), so every fixture here uses its own ids (f0…).
-- ASSERT-guarded; ON_ERROR_STOP aborts on the first failure.
--   V — vouchers: one use = one ticket; waitlist offers sized + seat-blocking
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('f0000000-0000-0000-0000-00000000000a','p0owner@x.com',now()),
  ('f0000000-0000-0000-0000-00000000000b','p0buyer@x.com',now()),
  ('f0000000-0000-0000-0000-00000000000c','p0wait1@x.com',now()),
  ('f0000000-0000-0000-0000-00000000000d','p0wait2@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('f0000000-0000-0000-0000-000000000001','P0 Org','p0-org','f0000000-0000-0000-0000-00000000000a');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-00000000000a','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold) VALUES
  ('f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-000000000001','P0 Show','p0-show','published',0,0);
-- t1: sold-out tier for the voucher cases. t2: waitlist tier. t3: oversold tier.
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('f0000000-0000-0000-0000-0000000000d1','f0000000-0000-0000-0000-0000000000e1','Sold out',50,2,2),
  ('f0000000-0000-0000-0000-0000000000d2','f0000000-0000-0000-0000-0000000000e1','Waitlisted',50,5,5),
  ('f0000000-0000-0000-0000-0000000000d3','f0000000-0000-0000-0000-0000000000e1','Oversold',50,2,4);

CREATE OR REPLACE FUNCTION pg_temp.p0_session(p_id text, p_tier uuid, p_qty int, p_voucher uuid) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,voucher_id)
  VALUES (p_id,'f0000000-0000-0000-0000-0000000000e1',p_tier,'f0000000-0000-0000-0000-000000000001',
          'f0000000-0000-0000-0000-00000000000b','p0buyer@x.com',p_qty,5000*p_qty,'pending',p_voucher);
$$;

-- V1. A single-use capacity-bypass voucher can't mint 3 tickets past sold-out.
DO $$
DECLARE v uuid; ids uuid[]; st text; used int;
BEGIN
  INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses,bypass_capacity)
    VALUES ('f0000000-0000-0000-0000-0000000000e1','P0ONE','f0000000-0000-0000-0000-0000000000d1',1,true)
    RETURNING id INTO v;
  PERFORM pg_temp.p0_session('p0-v1', 'f0000000-0000-0000-0000-0000000000d1', 3, v);
  ids := public.exos_fulfill_checkout('p0-v1');
  SELECT status INTO st FROM public.exos_checkout_sessions WHERE session_id='p0-v1';
  SELECT used_count INTO used FROM public.exos_vouchers WHERE id=v;
  ASSERT coalesce(array_length(ids,1),0) = 0, 'V1: a 1-use voucher must not mint 3 tickets';
  ASSERT st = 'failed', 'V1: session must fail';
  ASSERT used = 0, 'V1: a refused redemption must not spend the use';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='f0000000-0000-0000-0000-0000000000d1') = 2,
         'V1: tier sold must be unchanged';
  RAISE NOTICE 'OK  V1 single-use voucher cannot mint a 3-ticket order';
END $$;

-- V2. A 3-use voucher covers 2 + 1 tickets, then nothing more.
DO $$
DECLARE v uuid; a uuid[]; b uuid[]; c uuid[];
BEGIN
  INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses,bypass_capacity)
    VALUES ('f0000000-0000-0000-0000-0000000000e1','P0THREE','f0000000-0000-0000-0000-0000000000d1',3,true)
    RETURNING id INTO v;
  PERFORM pg_temp.p0_session('p0-v2a', 'f0000000-0000-0000-0000-0000000000d1', 2, v);
  PERFORM pg_temp.p0_session('p0-v2b', 'f0000000-0000-0000-0000-0000000000d1', 2, v);
  PERFORM pg_temp.p0_session('p0-v2c', 'f0000000-0000-0000-0000-0000000000d1', 1, v);
  a := public.exos_fulfill_checkout('p0-v2a');
  b := public.exos_fulfill_checkout('p0-v2b');
  c := public.exos_fulfill_checkout('p0-v2c');
  ASSERT array_length(a,1) = 2, 'V2: first order of 2 uses 2 of 3';
  ASSERT coalesce(array_length(b,1),0) = 0, 'V2: an order of 2 with 1 use left must fail';
  ASSERT array_length(c,1) = 1, 'V2: the last use still buys 1 ticket';
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE id=v) = 3, 'V2: all 3 uses spent';
  RAISE NOTICE 'OK  V2 multi-use voucher spends one use per ticket';
END $$;

-- V3. Waitlist offers carry the group size, wait FIFO for enough seats, and
--     block the seats they promise.
INSERT INTO public.exos_waitlist(id,event_id,tier_id,user_id,email,quantity,status,created_at) VALUES
  ('f0000000-0000-0000-0000-0000000000a1','f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-0000000000d2',
   'f0000000-0000-0000-0000-00000000000c','p0wait1@x.com',2,'waiting', now() - interval '2 hours'),
  ('f0000000-0000-0000-0000-0000000000a2','f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-0000000000d2',
   'f0000000-0000-0000-0000-00000000000d','p0wait2@x.com',1,'waiting', now() - interval '1 hour');
DO $$
DECLARE st1 text; st2 text; vmax int; vblock boolean; avail int;
BEGIN
  -- One seat frees up: the first group needs 2, so nobody is offered yet.
  UPDATE public.exos_ticket_tiers SET sold = 4 WHERE id='f0000000-0000-0000-0000-0000000000d2';
  SELECT status INTO st1 FROM public.exos_waitlist WHERE id='f0000000-0000-0000-0000-0000000000a1';
  SELECT status INTO st2 FROM public.exos_waitlist WHERE id='f0000000-0000-0000-0000-0000000000a2';
  ASSERT st1 = 'waiting' AND st2 = 'waiting', 'V3: 1 free seat must not jump the 2-person group or offer them 1';

  -- A second seat frees up: the group of 2 gets one offer for 2.
  UPDATE public.exos_ticket_tiers SET sold = 3 WHERE id='f0000000-0000-0000-0000-0000000000d2';
  SELECT status INTO st1 FROM public.exos_waitlist WHERE id='f0000000-0000-0000-0000-0000000000a1';
  SELECT status INTO st2 FROM public.exos_waitlist WHERE id='f0000000-0000-0000-0000-0000000000a2';
  SELECT v.max_uses, v.block_quota INTO vmax, vblock
    FROM public.exos_vouchers v JOIN public.exos_waitlist w ON w.voucher_id = v.id
   WHERE w.id='f0000000-0000-0000-0000-0000000000a1';
  ASSERT st1 = 'offered', 'V3: the group of 2 is offered once 2 seats are free';
  ASSERT st2 = 'waiting', 'V3: the next person waits';
  ASSERT vmax = 2, format('V3: the offer must cover the group size (max_uses 2), got %s', vmax);
  ASSERT vblock, 'V3: offer vouchers must block the seats';

  -- The 2 freed seats are reserved: a regular buyer sees none.
  avail := public.exos_tier_available('f0000000-0000-0000-0000-0000000000d2');
  ASSERT avail = 0, format('V3: offered seats must not be sellable to others, available %s', avail);
  RAISE NOTICE 'OK  V3 waitlist offer sized to the group and holds its seats';
END $$;

-- V4. Redeeming the offer fills exactly the reserved seats.
DO $$
DECLARE v uuid; ids uuid[];
BEGIN
  SELECT voucher_id INTO v FROM public.exos_waitlist WHERE id='f0000000-0000-0000-0000-0000000000a1';
  PERFORM pg_temp.p0_session('p0-v4', 'f0000000-0000-0000-0000-0000000000d2', 2, v);
  -- The offer voucher is reserved to the waiter; since mig 20260925021000
  -- fulfillment re-checks that, so the order is the waiter's (as at checkout).
  UPDATE public.exos_checkout_sessions SET buyer_uid = 'f0000000-0000-0000-0000-00000000000c', buyer_email = 'p0wait1@x.com'
   WHERE session_id = 'p0-v4';
  ids := public.exos_fulfill_checkout('p0-v4');
  ASSERT array_length(ids,1) = 2, 'V4: the offer buys the 2 reserved seats';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='f0000000-0000-0000-0000-0000000000d2') = 5,
         'V4: tier is exactly full, not oversold';
  ASSERT public.exos_tier_available('f0000000-0000-0000-0000-0000000000d2') = 0, 'V4: nothing left';
  RAISE NOTICE 'OK  V4 offer redemption fills the reserved seats exactly';
END $$;

-- V5. A refund on a tier that is still oversold offers nobody.
INSERT INTO public.exos_waitlist(id,event_id,tier_id,email,quantity,status) VALUES
  ('f0000000-0000-0000-0000-0000000000a3','f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-0000000000d3',
   'p0wait3@x.com',1,'waiting');
DO $$
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = 3 WHERE id='f0000000-0000-0000-0000-0000000000d3';
  ASSERT (SELECT status FROM public.exos_waitlist WHERE id='f0000000-0000-0000-0000-0000000000a3') = 'waiting',
         'V5: freeing a seat on an oversold tier must not create an offer';
  RAISE NOTICE 'OK  V5 no offers while the tier is still oversold';
END $$;

-- ============================================================================
-- H — cart holds: one live hold per buyer per event, purchase limits, confirmed
--     email, 30-minute TTL cap (mig 20260924205916)
-- ============================================================================
INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('f0000000-0000-0000-0000-00000000000e','p0unconfirmed@x.com',NULL);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('f0000000-0000-0000-0000-0000000000d4','f0000000-0000-0000-0000-0000000000e1','Holdable',50,20,0);

DO $$
DECLARE h1 uuid; h2 uuid; live int; raised boolean; exp timestamptz;
BEGIN
  PERFORM set_config('app.uid','f0000000-0000-0000-0000-00000000000b', true);
  PERFORM set_config('app.jwt','{"email":"p0buyer@x.com"}', true);

  -- H1. A second hold replaces the first instead of stacking.
  h1 := public.exos_create_hold('f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-0000000000d4',2);
  h2 := public.exos_create_hold('f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-0000000000d4',3);
  SELECT count(*) INTO live FROM public.exos_cart_holds
   WHERE buyer_uid='f0000000-0000-0000-0000-00000000000b' AND event_id='f0000000-0000-0000-0000-0000000000e1' AND status='active';
  ASSERT live = 1, format('H1: one live hold per buyer per event, found %s', live);
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE id=h1) = 'released', 'H1: the earlier hold is released';
  ASSERT public.exos_tier_available('f0000000-0000-0000-0000-0000000000d4') = 17, 'H1: only the live hold counts (20-3)';

  -- H4. TTL is capped at 30 minutes.
  h2 := public.exos_create_hold('f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-0000000000d4',1,3600);
  SELECT expires_at INTO exp FROM public.exos_cart_holds WHERE id=h2;
  ASSERT exp <= now() + interval '30 minutes 5 seconds', 'H4: hold TTL must be capped at 30 minutes';

  -- H3. maxPerAccount counts tickets already held.
  UPDATE public.exos_events SET purchase_limits = '{"maxPerAccount": 4}'::jsonb
   WHERE id='f0000000-0000-0000-0000-0000000000e1';
  INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret)
    SELECT 'f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-0000000000d4',
           'f0000000-0000-0000-0000-00000000000b','f0000000-0000-0000-0000-00000000000b','active',gen_random_uuid()::text
      FROM generate_series(1,3);
  raised := false;
  BEGIN
    PERFORM public.exos_create_hold('f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-0000000000d4',2);
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'H3: holding 2 with 3 already owned must exceed maxPerAccount 4';
  UPDATE public.exos_events SET purchase_limits = NULL WHERE id='f0000000-0000-0000-0000-0000000000e1';

  -- H2. An unconfirmed account can't hold seats.
  PERFORM set_config('app.uid','f0000000-0000-0000-0000-00000000000e', true);
  PERFORM set_config('app.jwt','{"email":"p0unconfirmed@x.com"}', true);
  raised := false;
  BEGIN
    PERFORM public.exos_create_hold('f0000000-0000-0000-0000-0000000000e1','f0000000-0000-0000-0000-0000000000d4',1);
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'H2: an unconfirmed email must not reserve seats';
  RAISE NOTICE 'OK  H1-H4 holds: one per buyer/event, limits, confirmed email, 30-min TTL';
END $$;

-- H5. authenticated can no longer probe another buyer's ticket count.
DO $$
BEGIN
  ASSERT NOT has_function_privilege('authenticated','public.exos_assert_purchase_limit(uuid,uuid,int)','EXECUTE'),
         'H5: exos_assert_purchase_limit must not be callable by authenticated';
  RAISE NOTICE 'OK  H5 purchase-limit probe revoked';
END $$;

-- ============================================================================
-- Q — every mint path respects shared quotas, live holds and offers
--     (mig 20260924210103)
-- ============================================================================
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold) VALUES
  ('f0000000-0000-0000-0000-0000000000e2','f0000000-0000-0000-0000-000000000001','P0 Free Show','p0-free','published',0,0);
-- d5 + d6 share a 3-seat quota; d7 is a 2-seat free tier for the hold case.
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('f0000000-0000-0000-0000-0000000000d5','f0000000-0000-0000-0000-0000000000e2','Free A',0,10,0,'public'),
  ('f0000000-0000-0000-0000-0000000000d6','f0000000-0000-0000-0000-0000000000e2','Free B',0,10,0,'public'),
  ('f0000000-0000-0000-0000-0000000000d7','f0000000-0000-0000-0000-0000000000e2','Free C',0,2,0,'public');
INSERT INTO public.exos_quotas(id,event_id,org_id,name,size) VALUES
  ('f0000000-0000-0000-0000-0000000000c1','f0000000-0000-0000-0000-0000000000e2','f0000000-0000-0000-0000-000000000001','Room',3);
INSERT INTO public.exos_quota_tiers(quota_id,tier_id) VALUES
  ('f0000000-0000-0000-0000-0000000000c1','f0000000-0000-0000-0000-0000000000d5'),
  ('f0000000-0000-0000-0000-0000000000c1','f0000000-0000-0000-0000-0000000000d6');

DO $$
DECLARE ids uuid[]; raised boolean; r record; n_sold int;
BEGIN
  -- Q1. Free claims across two tiers can't exceed the shared 3-seat quota.
  PERFORM set_config('app.uid','f0000000-0000-0000-0000-00000000000b', true);
  PERFORM set_config('app.jwt','{"email":"p0buyer@x.com"}', true);
  ids := public.exos_claim_free_tickets('f0000000-0000-0000-0000-0000000000e2','f0000000-0000-0000-0000-0000000000d5',2);
  ASSERT array_length(ids,1) = 2, 'Q1: 2 of the 3 shared seats';
  PERFORM set_config('app.uid','f0000000-0000-0000-0000-00000000000c', true);
  PERFORM set_config('app.jwt','{"email":"p0wait1@x.com"}', true);
  raised := false;
  BEGIN
    PERFORM public.exos_claim_free_tickets('f0000000-0000-0000-0000-0000000000e2','f0000000-0000-0000-0000-0000000000d6',2);
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'Q1: a 2-seat free claim on the other tier must hit the shared quota';
  ids := public.exos_claim_free_tickets('f0000000-0000-0000-0000-0000000000e2','f0000000-0000-0000-0000-0000000000d6',1);
  ASSERT array_length(ids,1) = 1, 'Q1: the last shared seat can still be claimed';

  -- Q2. A free claim can't take seats reserved by someone else's live hold.
  PERFORM set_config('app.uid','f0000000-0000-0000-0000-00000000000b', true);
  PERFORM set_config('app.jwt','{"email":"p0buyer@x.com"}', true);
  PERFORM public.exos_create_hold('f0000000-0000-0000-0000-0000000000e2','f0000000-0000-0000-0000-0000000000d7',2);
  PERFORM set_config('app.uid','f0000000-0000-0000-0000-00000000000d', true);
  PERFORM set_config('app.jwt','{"email":"p0wait2@x.com"}', true);
  raised := false;
  BEGIN
    PERFORM public.exos_claim_free_tickets('f0000000-0000-0000-0000-0000000000e2','f0000000-0000-0000-0000-0000000000d7',1);
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'Q2: seats held in someone''s cart must not be claimable';

  -- Q3. The comp batch reports sold-out per recipient instead of overselling.
  PERFORM set_config('app.uid','f0000000-0000-0000-0000-00000000000a', true);
  PERFORM set_config('app.jwt','{"email":"p0owner@x.com"}', true);
  SELECT * INTO r FROM public.exos_issue_comp_batch('f0000000-0000-0000-0000-0000000000e2',
         'f0000000-0000-0000-0000-0000000000d5', ARRAY['comp1@x.com'], 1);
  ASSERT r.outcome = 'sold-out', format('Q3: comp on an exhausted quota must be sold-out, got %s', r.outcome);

  -- Q4. Staff issue-to-email and the box-office mint refuse too.
  raised := false;
  BEGIN
    PERFORM public.exos_issue_ticket_to_email('f0000000-0000-0000-0000-0000000000e2',
            'f0000000-0000-0000-0000-0000000000d6', 'p0buyer@x.com', 1);
  EXCEPTION WHEN others THEN raised := SQLERRM LIKE '%sold out%';
  END;
  ASSERT raised, 'Q4: issue-to-email must respect the shared quota';
  raised := false;
  BEGIN
    PERFORM public.exos_mint_tickets('f0000000-0000-0000-0000-0000000000e2','f0000000-0000-0000-0000-0000000000d7',1);
  EXCEPTION WHEN others THEN raised := SQLERRM LIKE '%sold out%';
  END;
  ASSERT raised, 'Q4: the box-office mint must not take held seats';

  SELECT count(*) INTO n_sold FROM public.exos_tickets
   WHERE tier_id IN ('f0000000-0000-0000-0000-0000000000d5','f0000000-0000-0000-0000-0000000000d6') AND status <> 'voided';
  ASSERT n_sold = 3, format('Q: the shared quota ends at exactly 3 tickets, got %s', n_sold);
  RAISE NOTICE 'OK  Q1-Q4 free claim / comp batch / issue-to-email / box-office mint respect quotas + holds';
END $$;

-- ============================================================================
-- T — all-in pricing: the public views expose the exclusive tax rate
--     (mig 20260924211840)
-- ============================================================================
INSERT INTO public.exos_tax_rules(id,event_id,name,rate_percent,price_includes_tax) VALUES
  ('f0000000-0000-0000-0000-0000000000b1','f0000000-0000-0000-0000-0000000000e2','NYC 8.875%',8.875,false),
  ('f0000000-0000-0000-0000-0000000000b2','f0000000-0000-0000-0000-0000000000e2','VAT incl.',20,true);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility,tax_rate_id) VALUES
  ('f0000000-0000-0000-0000-0000000000d8','f0000000-0000-0000-0000-0000000000e2','Taxed',10.05,10,0,'public','f0000000-0000-0000-0000-0000000000b1'),
  ('f0000000-0000-0000-0000-0000000000d9','f0000000-0000-0000-0000-0000000000e2','Tax incl',10,10,0,'public','f0000000-0000-0000-0000-0000000000b2');
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity,sold,visibility,tax_rate_id) VALUES
  ('f0000000-0000-0000-0000-0000000000f1','f0000000-0000-0000-0000-0000000000e2','Taxed tee',20,10,0,'public','f0000000-0000-0000-0000-0000000000b1');
-- (Values checked as the owner: this harness doesn't load the anon column
-- grants on exos_events. anon's path is checked on prod after apply.)
DO $$
DECLARE r1 numeric; r2 numeric; r3 numeric; r4 numeric;
BEGIN
  SELECT exclusive_tax_percent INTO r1 FROM public.exos_public_tiers WHERE id='f0000000-0000-0000-0000-0000000000d8';
  SELECT exclusive_tax_percent INTO r2 FROM public.exos_public_tiers WHERE id='f0000000-0000-0000-0000-0000000000d9';
  SELECT exclusive_tax_percent INTO r3 FROM public.exos_public_tiers WHERE id='f0000000-0000-0000-0000-0000000000d5';
  SELECT exclusive_tax_percent INTO r4 FROM public.exos_public_addons WHERE id='f0000000-0000-0000-0000-0000000000f1';
  ASSERT r1 = 8.875, format('T: anon must see the exclusive rate on a public tier, got %s', r1);
  ASSERT r2 = 0, 'T: a tax-inclusive tier adds nothing';
  ASSERT r3 = 0, 'T: a tier with no tax rule adds nothing';
  ASSERT r4 = 8.875, 'T: add-ons expose their exclusive rate too';
  ASSERT has_function_privilege('anon','public.exos_tier_exclusive_tax_percent(uuid)','EXECUTE')
     AND has_function_privilege('anon','public.exos_addon_exclusive_tax_percent(uuid)','EXECUTE'),
         'T: anon must be able to evaluate the tax helpers behind the views';
  RAISE NOTICE 'OK  T all-in: exclusive tax visible to buyers (tier + add-on), 0 when included/none';
END $$;

SELECT '*** EXOS P0 TESTS PASSED ***';
