-- ============================================================================
-- Fan referrals (mig 20260924234500). Runs after test_promoters.sql in the
-- same DB. Fan A = f1…0b (holds the paid f1-p1 tickets), friend B = f1…cc.
-- ============================================================================
\set ON_ERROR_STOP on

-- F1. A code needs a ticket; it's stable once issued.
SELECT set_config('app.uid','f1000000-0000-0000-0000-0000000000cc',false);
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_my_referral_code('f1000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'F1: a non-holder got a referral code';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  F1a no ticket, no code';
END $$;
SELECT set_config('app.uid','f1000000-0000-0000-0000-00000000000b',false);
DO $$
DECLARE a text; b text;
BEGIN
  a := public.exos_my_referral_code('f1000000-0000-0000-0000-0000000000e1');
  b := public.exos_my_referral_code('f1000000-0000-0000-0000-0000000000e1');
  ASSERT a ~ '^[a-z0-9]{10}$' AND a = b, 'F1: stable 10-char code, got ' || a || ' / ' || b;
  PERFORM set_config('test.ref_a', a, false);
  RAISE NOTICE 'OK  F1b holder gets one stable code';
END $$;

-- F2. Paid: a friend's order through A's link is credited; A's own purchase
--     through their own link isn't.
DO $$
DECLARE ref text := current_setting('test.ref_a'); ids uuid[];
BEGIN
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,attribution)
  VALUES ('f1-r1','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d9','f1000000-0000-0000-0000-000000000001',
          'f1000000-0000-0000-0000-0000000000cc','f1stranger@x.com',2,4000,'pending', jsonb_build_object('ref', ref)),
         ('f1-r2','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d9','f1000000-0000-0000-0000-000000000001',
          'f1000000-0000-0000-0000-00000000000b','f1buyer@x.com',1,2000,'pending', jsonb_build_object('ref', ref));
  ids := public.exos_fulfill_checkout('f1-r1');
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='f1-r1' AND referral_code=ref) = 2, 'F2: friend credited';
  ids := public.exos_fulfill_checkout('f1-r2');
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='f1-r2' AND referral_code IS NULL) = 1, 'F2: no self-referral';
  RAISE NOTICE 'OK  F2 paid referrals credited, self-referral ignored';
END $$;

-- F3. Free claims: attach right after the claim; once; never your own code.
DO $$
DECLARE ref text := current_setting('test.ref_a'); n int;
BEGIN
  INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,price_paid,order_ref,barcode_secret)
  VALUES ('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-0000000000d9',
          'f1000000-0000-0000-0000-0000000000cc','f1000000-0000-0000-0000-0000000000cc','active',0,'f1-free','test-secret');
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-0000000000cc',false);
  n := public.exos_attach_referral('f1-free', ref);
  ASSERT n = 1, 'F3: free claim credited, got ' || n;
  ASSERT public.exos_attach_referral('f1-free', ref) = 0, 'F3: only once';
  ASSERT public.exos_attach_referral('f1-r1', 'zzzzzzzzzz') = 0, 'F3: unknown code does nothing';
  -- A's code is for e1; it can't credit a ticket to another event.
  INSERT INTO public.exos_tickets(event_id,org_id,buyer_id,owner_id,status,price_paid,order_ref,barcode_secret)
  VALUES ('f1000000-0000-0000-0000-0000000000e2','f1000000-0000-0000-0000-000000000001',
          'f1000000-0000-0000-0000-0000000000cc','f1000000-0000-0000-0000-0000000000cc','active',0,'f1-free-e2','test-secret');
  ASSERT public.exos_attach_referral('f1-free-e2', ref) = 0, 'F3: code is scoped to its event';
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-00000000000b',false);
  ASSERT public.exos_attach_referral('f1-r2', ref) = 0, 'F3: own code never attaches';
  RAISE NOTICE 'OK  F3 free-claim attach';
END $$;

-- F4. A sees their numbers: one friend (B), three tickets.
DO $$
DECLARE st jsonb := public.exos_my_referral_stats('f1000000-0000-0000-0000-0000000000e1');
BEGIN
  ASSERT (st->>'friends')::int = 1 AND (st->>'tickets')::int = 3, 'F4: stats, got ' || st::text;
  RAISE NOTICE 'OK  F4 referral stats';
END $$;
SELECT set_config('app.uid','',false);
