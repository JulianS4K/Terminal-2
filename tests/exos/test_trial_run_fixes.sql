-- ============================================================================
-- Fixes from the 2026-09-25 end-to-end trial (mig 20260925003000). Runs last
-- in run_p0.sh; reuses the f1 org (owner f1…0b), event e1 and the hidden
-- Presale tier f5 from test_voucher_tier.sql.
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('f1000000-0000-0000-0000-0000000000ab','f1unconfirmed@x.com',NULL);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('f1000000-0000-0000-0000-0000000000da','f1000000-0000-0000-0000-0000000000e1','Trial GA',25,10,0,'public'),
  ('f1000000-0000-0000-0000-0000000000db','f1000000-0000-0000-0000-0000000000e1','Trial Guest List',0,10,0,'public');
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity) VALUES
  ('f1000000-0000-0000-0000-0000000000ad','f1000000-0000-0000-0000-0000000000e1','Poster',10,5);
INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses) VALUES
  ('f1000000-0000-0000-0000-0000000000e1','F1HOLD','f1000000-0000-0000-0000-0000000000f5',5);

-- T1. Add-ons are not folded into each ticket's price_paid.
DO $$
DECLARE ids uuid[];
BEGIN
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,
                                           quantity,amount_cents,status,addons)
  VALUES ('f1-t1','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000da',
          'f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-00000000000b','f1buyer@x.com',
          2,6444,'pending',
          '[{"addon_id":"f1000000-0000-0000-0000-0000000000ad","quantity":1,"unit_price_cents":1000,"name":"Poster"}]');
  ids := public.exos_fulfill_checkout('f1-t1');
  ASSERT array_length(ids,1) = 2, 'T1: order fulfills';
  ASSERT (SELECT array_agg(DISTINCT price_paid) FROM public.exos_tickets WHERE order_ref='f1-t1') = ARRAY[27.22],
         'T1: each ticket is (6444 - 1000) / 2 = 27.22';
  RAISE NOTICE 'OK  T1 price_paid excludes add-ons';
END $$;

-- T2. Analytics: add-on revenue, partial refunds and net revenue.
DO $$
DECLARE a jsonb;
BEGIN
  INSERT INTO public.exos_order_refunds(session_id,org_id,refund_id,amount_cents,status,is_partial)
  VALUES ('f1-t1','f1000000-0000-0000-0000-000000000001','re_f1_t1',1000,'succeeded',true);
  UPDATE public.exos_checkout_sessions SET status='partially_refunded' WHERE session_id='f1-t1';
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-00000000000b',false);
  a := public.exos_event_analytics('f1000000-0000-0000-0000-0000000000e1');
  ASSERT (a->>'addon_revenue')::numeric >= 10, 'T2: add-on revenue counts the poster, got '||(a->>'addon_revenue');
  ASSERT (a->>'partial_refunds')::numeric = 10, 'T2: partial refunds 10, got '||(a->>'partial_refunds');
  ASSERT (a->>'net_revenue')::numeric = (a->>'revenue')::numeric + (a->>'addon_revenue')::numeric - 10,
         'T2: net = tickets + add-ons - partial refunds';
  RAISE NOTICE 'OK  T2 analytics net revenue';
END $$;

-- T3. A full refund voids a ticket that was already scanned; its seat stays taken.
DO $$
DECLARE v_sold int; a jsonb; v_addons numeric;
BEGIN
  v_addons := (public.exos_event_analytics('f1000000-0000-0000-0000-0000000000e1')->>'addon_revenue')::numeric;
  UPDATE public.exos_tickets SET status='used'
   WHERE id = (SELECT id FROM public.exos_tickets WHERE order_ref='f1-t1' ORDER BY id LIMIT 1);
  SELECT sold INTO v_sold FROM public.exos_ticket_tiers WHERE id='f1000000-0000-0000-0000-0000000000da';
  ASSERT public.exos_refund_checkout('f1-t1') = 1, 'T3: one active ticket released';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='f1-t1' AND status='voided') = 2,
         'T3: both tickets voided, scanned one included';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='f1000000-0000-0000-0000-0000000000da') = v_sold - 1,
         'T3: only the unscanned seat goes back on sale';
  ASSERT public.exos_refund_checkout('f1-t1') = 0, 'T3: replay is a no-op';
  a := public.exos_event_analytics('f1000000-0000-0000-0000-0000000000e1');
  ASSERT (a->>'partial_refunds')::numeric = 0 AND (a->>'addon_revenue')::numeric = v_addons - 10,
         'T3: a fully refunded order leaves no partial refund or add-on revenue';
  RAISE NOTICE 'OK  T3 full refund voids scanned tickets';
END $$;

-- T4. Free claims need a confirmed email.
DO $$
BEGIN
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-0000000000ab',false);
  BEGIN
    PERFORM public.exos_claim_free_tickets('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000db',1);
    RAISE EXCEPTION 'T4: unconfirmed user claimed a free ticket';
  EXCEPTION WHEN insufficient_privilege THEN
    ASSERT SQLERRM LIKE '%confirm your email%', 'T4: clear message, got '||SQLERRM;
  END;
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-0000000000cc',false);
  ASSERT array_length(public.exos_claim_free_tickets('f1000000-0000-0000-0000-0000000000e1',
           'f1000000-0000-0000-0000-0000000000db',1),1) = 1, 'T4: confirmed user still claims';
  RAISE NOTICE 'OK  T4 free claims need a confirmed email';
END $$;

-- T5. A hidden tier can only be held with its voucher.
DO $$
DECLARE h uuid;
BEGIN
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-0000000000cc',false);
  PERFORM set_config('app.jwt','{"email":"f1stranger@x.com"}',false);
  BEGIN
    PERFORM public.exos_create_hold('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000f5',2);
    RAISE EXCEPTION 'T5: hidden tier held without a voucher';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_create_hold('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000f5',2,1800,'WRONG');
    RAISE EXCEPTION 'T5: hidden tier held with a bad code';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  h := public.exos_create_hold('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000f5',2,1800,'F1HOLD');
  ASSERT h IS NOT NULL, 'T5: hold with the voucher';
  h := public.exos_create_hold('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000da',1);
  ASSERT h IS NOT NULL, 'T5: public tier needs no voucher';
  ASSERT NOT has_function_privilege('anon','public.exos_effective_available(uuid)','EXECUTE')
     AND NOT has_function_privilege('authenticated','public.exos_tier_available(uuid)','EXECUTE'),
         'T5: stock helpers not callable by clients';
  RAISE NOTICE 'OK  T5 hidden-tier holds need the voucher';
END $$;
