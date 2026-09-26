-- ============================================================================
-- Fulfillment is all-or-nothing (mig 20260924215000). Runs after test_p0.sql
-- in the same DB (run_p0.sh); fixtures use their own ids (f1…).
--   A1 add-ons can't oversell   A2 a failed house cap leaves tier sold alone
--   A3 a failed order keeps its voucher use and waitlist offer
--   A4 a failed order releases its cart hold   A5 a clean order still fulfills
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('f1000000-0000-0000-0000-00000000000b','f1buyer@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('f1000000-0000-0000-0000-000000000001','F1 Org','f1-org','f1000000-0000-0000-0000-00000000000b');
-- e1: open event. e2: house-capped event that is already full.
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold) VALUES
  ('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-000000000001','F1 Show','f1-show','published',0,0),
  ('f1000000-0000-0000-0000-0000000000e2','f1000000-0000-0000-0000-000000000001','F1 Full','f1-full','published',1,1);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('f1000000-0000-0000-0000-0000000000d1','f1000000-0000-0000-0000-0000000000e1','GA',20,10,0),
  ('f1000000-0000-0000-0000-0000000000d2','f1000000-0000-0000-0000-0000000000e2','GA',20,10,0),
  ('f1000000-0000-0000-0000-0000000000d3','f1000000-0000-0000-0000-0000000000e1','Sold out',20,1,1);
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity,sold) VALUES
  ('f1000000-0000-0000-0000-0000000000a1','f1000000-0000-0000-0000-0000000000e1','Parking',10,1,0);

CREATE OR REPLACE FUNCTION pg_temp.f1_session(p_id text, p_event uuid, p_tier uuid, p_qty int,
                                              p_voucher uuid, p_addons jsonb) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,
                                           quantity,amount_cents,status,voucher_id,addons)
  VALUES (p_id,p_event,p_tier,'f1000000-0000-0000-0000-000000000001',
          'f1000000-0000-0000-0000-00000000000b','f1buyer@x.com',p_qty,2000*p_qty,'pending',p_voucher,p_addons);
$$;

-- A1. Two paid sessions both carry the last add-on; only the first gets it,
--     and the second rolls back entirely (no tickets, tier sold unchanged).
DO $$
DECLARE a uuid[]; b uuid[]; st text; why text; parking jsonb :=
  '[{"addon_id":"f1000000-0000-0000-0000-0000000000a1","quantity":1,"unit_price_cents":1000,"name":"Parking"}]';
BEGIN
  PERFORM pg_temp.f1_session('f1-a1a','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d1',1,NULL,parking);
  PERFORM pg_temp.f1_session('f1-a1b','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d1',2,NULL,parking);
  a := public.exos_fulfill_checkout('f1-a1a');
  b := public.exos_fulfill_checkout('f1-a1b');
  SELECT status, failure_reason INTO st, why FROM public.exos_checkout_sessions WHERE session_id='f1-a1b';
  ASSERT array_length(a,1) = 1, 'A1: first order fulfills';
  ASSERT coalesce(array_length(b,1),0) = 0, 'A1: second order must not fulfill';
  ASSERT st = 'failed' AND why LIKE 'add-on%sold out%', 'A1: second order fails on the add-on, got ' || coalesce(why,'null');
  ASSERT (SELECT sold FROM public.exos_event_addons WHERE id='f1000000-0000-0000-0000-0000000000a1') = 1, 'A1: add-on sold stays at capacity';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='f1000000-0000-0000-0000-0000000000d1') = 1, 'A1: failed order leaves tier sold alone';
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='f1000000-0000-0000-0000-0000000000e1') = 1, 'A1: failed order leaves event sold alone';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref='f1-a1b'), 'A1: failed order mints nothing';
  RAISE NOTICE 'OK  A1 add-ons cannot oversell; the losing order rolls back';
END $$;

-- A2. The event house cap fails after the tier claim: tier sold must not leak.
DO $$
DECLARE ids uuid[];
BEGIN
  PERFORM pg_temp.f1_session('f1-a2','f1000000-0000-0000-0000-0000000000e2','f1000000-0000-0000-0000-0000000000d2',1,NULL,NULL);
  ids := public.exos_fulfill_checkout('f1-a2');
  ASSERT coalesce(array_length(ids,1),0) = 0, 'A2: full event must not fulfill';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='f1000000-0000-0000-0000-0000000000d2') = 0,
         'A2: tier sold must not stay bumped after the house cap fails';
  RAISE NOTICE 'OK  A2 failed house cap leaves tier sold unchanged';
END $$;

-- A3. A non-bypass voucher on a sold-out tier: the order fails but the buyer
--     keeps the voucher use and the waitlist offer.
DO $$
DECLARE v uuid; ids uuid[];
BEGIN
  INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses,bypass_capacity)
    VALUES ('f1000000-0000-0000-0000-0000000000e1','F1KEEP','f1000000-0000-0000-0000-0000000000d3',1,false)
    RETURNING id INTO v;
  INSERT INTO public.exos_waitlist(event_id,tier_id,user_id,email,quantity,status,voucher_id)
    VALUES ('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d3',
            'f1000000-0000-0000-0000-00000000000b','f1buyer@x.com',1,'offered',v);
  PERFORM pg_temp.f1_session('f1-a3','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d3',1,v,NULL);
  ids := public.exos_fulfill_checkout('f1-a3');
  ASSERT coalesce(array_length(ids,1),0) = 0, 'A3: sold-out tier must not fulfill';
  ASSERT (SELECT used_count FROM public.exos_vouchers WHERE id=v) = 0, 'A3: voucher use must not be burned';
  ASSERT (SELECT status FROM public.exos_waitlist WHERE voucher_id=v) = 'offered', 'A3: waitlist offer must stay open';
  RAISE NOTICE 'OK  A3 failed order keeps its voucher use and waitlist offer';
END $$;

-- A4. A failed order's cart hold is released at once, not left to expire.
DO $$
DECLARE ids uuid[];
BEGIN
  PERFORM pg_temp.f1_session('f1-a4','f1000000-0000-0000-0000-0000000000e2','f1000000-0000-0000-0000-0000000000d2',1,NULL,NULL);
  INSERT INTO public.exos_cart_holds(event_id,tier_id,org_id,buyer_uid,quantity,status,checkout_session_id,expires_at)
    VALUES ('f1000000-0000-0000-0000-0000000000e2','f1000000-0000-0000-0000-0000000000d2','f1000000-0000-0000-0000-000000000001',
            'f1000000-0000-0000-0000-00000000000b',1,'active','f1-a4',now() + interval '20 minutes');
  ids := public.exos_fulfill_checkout('f1-a4');
  ASSERT (SELECT status FROM public.exos_cart_holds WHERE checkout_session_id='f1-a4') = 'released',
         'A4: hold must be released when fulfillment fails';
  RAISE NOTICE 'OK  A4 failed order releases its hold';
END $$;

-- A5. Replaying a fulfilled session returns the same tickets and claims nothing twice.
DO $$
DECLARE again uuid[];
BEGIN
  again := public.exos_fulfill_checkout('f1-a1a');
  ASSERT array_length(again,1) = 1, 'A5: replay returns the original tickets';
  ASSERT (SELECT sold FROM public.exos_event_addons WHERE id='f1000000-0000-0000-0000-0000000000a1') = 1, 'A5: replay claims no add-on';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='f1000000-0000-0000-0000-0000000000d1') = 1, 'A5: replay claims no seat';
  RAISE NOTICE 'OK  A5 replay is idempotent';
END $$;
