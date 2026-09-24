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

SELECT '*** EXOS P0 TESTS PASSED ***';
