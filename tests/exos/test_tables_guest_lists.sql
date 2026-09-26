-- ============================================================================
-- Nightlife tables + guest lists (mig 20260926050000). Self-contained: own
-- fixtures (c9…), everything inside one transaction that is rolled back.
--   T1 free table claim mints party_size tickets + one booking
--   T2 a shared quota counts party_size (tickets and holds)
--   T3 sold-out tables block        T4 all-or-nothing (fulfill + claim), refund
--   T5 no single-ticket mints of a table tier   T6 label assignment is role-checked
--   T7 kind / party size lock after sales        T8 no self-release of a table ticket
--   G1 list admin roles   G2 cap + plus-one limit   G3 promoter only on own list
--   G4 door partial arrivals, no overshoot, idempotent replay
--   G5 scanner checks in but can't edit / read contact data
--   G6 non-staff and anon blocked   G7 counts-toward-capacity   G8 edits vs arrivals
-- Run against a DB with every exos migration + 20260926050000 applied.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

GRANT USAGE ON SCHEMA auth TO anon, authenticated;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c9000000-0000-0000-0000-0000000000a0','c9owner@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a1','c9scanner@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a2','c9buyer@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a3','c9buyer2@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a4','c9stranger@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a5','c9content@x.com',now()),
  ('c9000000-0000-0000-0000-0000000000a6','c9buyer3@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c9000000-0000-0000-0000-000000000001','C9 Club','c9-club','c9000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a0','owner'),
  ('c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a1','scanner'),
  ('c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000a5','content');
-- e1: the club night. e2: house cap 2 (too small for a table of 3). e3: house cap 3.
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold) VALUES
  ('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-000000000001','C9 Night','c9-night','published',0,0),
  ('c9000000-0000-0000-0000-0000000000e2','c9000000-0000-0000-0000-000000000001','C9 Small','c9-small','published',2,0),
  ('c9000000-0000-0000-0000-0000000000e3','c9000000-0000-0000-0000-000000000001','C9 Cap','c9-cap','published',3,0);
-- d1: free table for 4 (2 tables, min spend $500). d2: GA. d3: free table for 2, 1 table.
-- d4: paid table for 3 ($300 deposit). d5: paid table for 3 on the capped event.
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,kind,party_size,min_spend_cents,section_label) VALUES
  ('c9000000-0000-0000-0000-0000000000d1','c9000000-0000-0000-0000-0000000000e1','Booth',0,2,0,'table',4,50000,'Main floor'),
  ('c9000000-0000-0000-0000-0000000000d3','c9000000-0000-0000-0000-0000000000e1','Two-top',0,1,0,'table',2,NULL,NULL),
  ('c9000000-0000-0000-0000-0000000000d4','c9000000-0000-0000-0000-0000000000e1','VIP table',300,1,0,'table',3,100000,'Mezz'),
  ('c9000000-0000-0000-0000-0000000000d5','c9000000-0000-0000-0000-0000000000e2','VIP table',300,5,0,'table',3,NULL,NULL);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('c9000000-0000-0000-0000-0000000000d2','c9000000-0000-0000-0000-0000000000e1','GA',0,100,0);
INSERT INTO public.exos_quotas(id,event_id,org_id,name,size) VALUES
  ('c9000000-0000-0000-0000-0000000000f1','c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-000000000001','Room',10);
INSERT INTO public.exos_quota_tiers(quota_id,tier_id) VALUES
  ('c9000000-0000-0000-0000-0000000000f1','c9000000-0000-0000-0000-0000000000d1'),
  ('c9000000-0000-0000-0000-0000000000f1','c9000000-0000-0000-0000-0000000000d2');
INSERT INTO public.exos_promoters(id,org_id,code,name) VALUES
  ('c9000000-0000-0000-0000-0000000000b1','c9000000-0000-0000-0000-000000000001','nina','Nina'),
  ('c9000000-0000-0000-0000-0000000000b2','c9000000-0000-0000-0000-000000000001','omar','Omar');

-- T1 ---------------------------------------------------------------------------
SELECT set_config('app.uid','c9000000-0000-0000-0000-0000000000a2',true);
DO $$
DECLARE ids uuid[]; b record;
BEGIN
  ids := public.exos_claim_free_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d1',1,NULL,NULL,'c9-t1');
  ASSERT array_length(ids,1) = 4, 'T1: a table for 4 mints 4 tickets, got ' || coalesce(array_length(ids,1),0);
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='c9-t1' AND owner_id='c9000000-0000-0000-0000-0000000000a2') = 4,
         'T1: all four in one order, owned by the host';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='c9000000-0000-0000-0000-0000000000d1') = 1, 'T1: tier sold counts tables';
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='c9000000-0000-0000-0000-0000000000e1') = 4, 'T1: house count is admissions';
  SELECT * INTO b FROM public.exos_table_bookings WHERE order_ref='c9-t1';
  ASSERT b.party_size = 4 AND array_length(b.ticket_ids,1) = 4 AND b.host_uid = 'c9000000-0000-0000-0000-0000000000a2'
         AND b.ticket_ids @> ids AND b.status = 'active', 'T1: one booking holding the four tickets';
  -- Same order ref again = the same tickets (idempotent retry), no new booking.
  ids := public.exos_claim_free_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d1',1,NULL,NULL,'c9-t1');
  ASSERT array_length(ids,1) = 4 AND (SELECT count(*) FROM public.exos_table_bookings WHERE order_ref='c9-t1') = 1, 'T1: retry is idempotent';
  ASSERT current_setting('exos.table_mint', true) = '', 'T1: the mint marker is cleared';
  RAISE NOTICE 'OK  T1 table claim mints party_size tickets in one order + one booking';
END $$;

-- T2 ---------------------------------------------------------------------------
DO $$
DECLARE hid uuid;
BEGIN
  ASSERT public.exos_quota_available('c9000000-0000-0000-0000-0000000000f1') = 6, 'T2: 4 of 10 used by one table';
  ASSERT public.exos_effective_available('c9000000-0000-0000-0000-0000000000d2') = 6, 'T2: GA sees 6 seats';
  ASSERT public.exos_effective_available('c9000000-0000-0000-0000-0000000000d1') = 1, 'T2: one more whole table fits';
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a3',true);
  hid := public.exos_create_hold('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d1',1,600,NULL);
  ASSERT public.exos_quota_available('c9000000-0000-0000-0000-0000000000f1') = 2, 'T2: a held table reserves 4 quota seats';
  ASSERT public.exos_effective_available('c9000000-0000-0000-0000-0000000000d2') = 2, 'T2: GA sees 2 while the table is held';
  ASSERT public.exos_effective_available('c9000000-0000-0000-0000-0000000000d1') = 0, 'T2: no table left while held';
  ASSERT NOT public.exos_seats_available('c9000000-0000-0000-0000-0000000000d2', 3), 'T2: 3 GA do not fit';
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a6',true);
  BEGIN
    PERFORM public.exos_claim_free_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d2',3,NULL,NULL,'c9-t2-ga');
    RAISE EXCEPTION 'T2: 3 GA claimed past the held table';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_assert_quota('c9000000-0000-0000-0000-0000000000d1', 1);
    RAISE EXCEPTION 'T2: assert_quota let a table through with 2 seats left';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE public.exos_cart_holds SET status='released', released_at=now() WHERE id=hid;
  ASSERT public.exos_quota_available('c9000000-0000-0000-0000-0000000000f1') = 6, 'T2: released hold frees 4';
  PERFORM public.exos_assert_quota('c9000000-0000-0000-0000-0000000000d1', 1);
  RAISE NOTICE 'OK  T2 quota counts party_size for tickets, holds and asserts';
END $$;

-- T3 ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a3',true);
  PERFORM public.exos_claim_free_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d3',1,NULL,NULL,'c9-t3a');
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a6',true);
  BEGIN
    PERFORM public.exos_claim_free_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d3',1,NULL,NULL,'c9-t3b');
    RAISE EXCEPTION 'T3: a second table sold past capacity 1';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref='c9-t3b'), 'T3: nothing minted';
  -- Booth: 1 of 2 sold, quota has 6 - 2 (two-top is outside the quota) → 6 left, table fits; then sold out.
  PERFORM public.exos_claim_free_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d1',1,NULL,NULL,'c9-t3c');
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a4',true);
  BEGIN
    PERFORM public.exos_claim_free_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d1',1,NULL,NULL,'c9-t3d');
    RAISE EXCEPTION 'T3: a third booth sold';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='c9000000-0000-0000-0000-0000000000d1') = 2, 'T3: booths sold out at 2';
  ASSERT public.exos_quota_available('c9000000-0000-0000-0000-0000000000f1') = 2, 'T3: two booths use 8 of the room';
  RAISE NOTICE 'OK  T3 sold-out tables block';
END $$;

-- T4 ---------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status) VALUES
  ('c9-paid-ok','c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d4','c9000000-0000-0000-0000-000000000001',
   'c9000000-0000-0000-0000-0000000000a2','c9buyer@x.com',1,30000,'pending'),
  ('c9-paid-cap','c9000000-0000-0000-0000-0000000000e2','c9000000-0000-0000-0000-0000000000d5','c9000000-0000-0000-0000-000000000001',
   'c9000000-0000-0000-0000-0000000000a2','c9buyer@x.com',1,30000,'pending');
DO $$
DECLARE ids uuid[]; st text;
BEGIN
  ids := public.exos_fulfill_checkout('c9-paid-ok');
  ASSERT array_length(ids,1) = 3, 'T4: paid table fulfils 3 tickets';
  ASSERT (SELECT bool_and(price_paid = 100) FROM public.exos_tickets WHERE order_ref='c9-paid-ok'), 'T4: deposit split per admission';
  ASSERT (SELECT count(*) FROM public.exos_table_bookings WHERE order_ref='c9-paid-ok') = 1, 'T4: one booking';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='c9000000-0000-0000-0000-0000000000d4') = 1, 'T4: tier sold 1';
  -- House cap 2 < party of 3: the whole order fails and nothing sticks.
  ids := public.exos_fulfill_checkout('c9-paid-cap');
  SELECT status INTO st FROM public.exos_checkout_sessions WHERE session_id='c9-paid-cap';
  ASSERT coalesce(array_length(ids,1),0) = 0 AND st = 'failed', 'T4: capped order fails';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref='c9-paid-cap'), 'T4: no tickets';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_table_bookings WHERE order_ref='c9-paid-cap'), 'T4: no booking';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='c9000000-0000-0000-0000-0000000000d5') = 0, 'T4: tier sold untouched';
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='c9000000-0000-0000-0000-0000000000e2') = 0, 'T4: house untouched';
  -- Free claim on a table that doesn't fit the house: raises, nothing sticks.
  UPDATE public.exos_ticket_tiers SET price = 0 WHERE id='c9000000-0000-0000-0000-0000000000d5';
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a3',true);
  BEGIN
    PERFORM public.exos_claim_free_tickets('c9000000-0000-0000-0000-0000000000e2','c9000000-0000-0000-0000-0000000000d5',1,NULL,NULL,'c9-t4-free');
    RAISE EXCEPTION 'T4: free table claimed past the house cap';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE order_ref='c9-t4-free')
     AND (SELECT sold FROM public.exos_ticket_tiers WHERE id='c9000000-0000-0000-0000-0000000000d5') = 0
     AND NOT EXISTS (SELECT 1 FROM public.exos_table_bookings WHERE order_ref='c9-t4-free'), 'T4: failed free claim leaves nothing';
  -- Refund frees the table and the three admissions.
  ASSERT public.exos_refund_checkout('c9-paid-ok','refunded') = 3, 'T4: refund voids 3';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='c9000000-0000-0000-0000-0000000000d4') = 0, 'T4: refund gives the table back';
  ASSERT (SELECT status FROM public.exos_table_bookings WHERE order_ref='c9-paid-ok') = 'cancelled', 'T4: booking cancelled';
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='c9000000-0000-0000-0000-0000000000e1') = 10, 'T4: house back to 10 (4+2+4)';
  RAISE NOTICE 'OK  T4 table orders are all-or-nothing; refunds give the table back';
END $$;

-- T5 ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a0',true);
  BEGIN
    PERFORM public.exos_mint_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d4',1,'c9-bo',100,NULL);
    RAISE EXCEPTION 'T5: box office minted one ticket of a table';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.exos_tickets(event_id,org_id,tier_id,owner_id,status,order_ref)
    VALUES ('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-000000000001','c9000000-0000-0000-0000-0000000000d4',
            'c9000000-0000-0000-0000-0000000000a0','active','c9-raw');
    RAISE EXCEPTION 'T5: raw insert of a table ticket';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- A standard tier is unaffected.
  PERFORM public.exos_mint_tickets('c9000000-0000-0000-0000-0000000000e1','c9000000-0000-0000-0000-0000000000d2',1,'c9-bo-ga',20,NULL);
  RAISE NOTICE 'OK  T5 tables can only be sold whole';
END $$;

-- T6 ---------------------------------------------------------------------------
DO $$
DECLARE b1 uuid; b2 uuid; n int;
BEGIN
  SELECT id INTO b1 FROM public.exos_table_bookings WHERE order_ref='c9-t1';
  SELECT id INTO b2 FROM public.exos_table_bookings WHERE order_ref='c9-t3c';
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a1',true);   -- scanner
  BEGIN
    PERFORM public.exos_assign_table(b1, 'Table 12');
    RAISE EXCEPTION 'T6: scanner assigned a table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.exos_event_tables('c9000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'T6: scanner read the table list (host emails)';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a4',true);   -- stranger
  BEGIN
    PERFORM public.exos_assign_table(b1, 'Table 12');
    RAISE EXCEPTION 'T6: stranger assigned a table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a0',true);   -- owner
  PERFORM public.exos_assign_table(b1, ' Table 12 ');
  ASSERT (SELECT label FROM public.exos_table_bookings WHERE id=b1) = 'Table 12', 'T6: label set (trimmed)';
  BEGIN
    PERFORM public.exos_assign_table(b2, 'table 12');
    RAISE EXCEPTION 'T6: the same table number went to two bookings';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  PERFORM public.exos_assign_table(b2, 'Table 7');
  SELECT count(*) INTO n FROM public.exos_event_tables('c9000000-0000-0000-0000-0000000000e1') WHERE label IN ('Table 12','Table 7');
  ASSERT n = 2, 'T6: owner lists labelled tables';
  ASSERT (SELECT min_spend_cents FROM public.exos_event_tables('c9000000-0000-0000-0000-0000000000e1') WHERE booking_id=b1) = 50000,
         'T6: min spend in the organizer list';
  RAISE NOTICE 'OK  T6 table labels: owner/manager only, unique per event';
END $$;

-- T7 / T8 ------------------------------------------------------------------------
DO $$
DECLARE tid uuid;
BEGIN
  BEGIN
    UPDATE public.exos_ticket_tiers SET party_size = 6 WHERE id='c9000000-0000-0000-0000-0000000000d1';
    RAISE EXCEPTION 'T7: party size changed after sales';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_ticket_tiers SET kind = 'standard' WHERE id='c9000000-0000-0000-0000-0000000000d1';
    RAISE EXCEPTION 'T7: table turned into a standard tier after sales';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE public.exos_ticket_tiers SET min_spend_cents = 60000, section_label = 'Floor' WHERE id='c9000000-0000-0000-0000-0000000000d1';
  -- An unsold tier can still change.
  UPDATE public.exos_ticket_tiers SET party_size = 4 WHERE id='c9000000-0000-0000-0000-0000000000d5';
  ASSERT (SELECT party_size FROM public.exos_ticket_tiers WHERE id='c9000000-0000-0000-0000-0000000000d5') = 4, 'T7: unsold tier edits';
  UPDATE public.exos_ticket_tiers SET party_size = 3 WHERE id='c9000000-0000-0000-0000-0000000000d5';
  RAISE NOTICE 'OK  T7 kind / party size lock once sold';

  SELECT ticket_ids[2] INTO tid FROM public.exos_table_bookings WHERE order_ref='c9-t1';
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a2',true);
  BEGIN
    PERFORM public.exos_release_ticket(tid);
    RAISE EXCEPTION 'T8: a guest released one seat of a table';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%whole table%' THEN RAISE; END IF;
  END;
  -- The organizer cancels the free two-top as a whole.
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a0',true);
  ASSERT public.exos_cancel_table_booking((SELECT id FROM public.exos_table_bookings WHERE order_ref='c9-t3a')) = 2, 'T8: cancel voids 2';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='c9000000-0000-0000-0000-0000000000d3') = 0, 'T8: two-top back on sale';
  RAISE NOTICE 'OK  T8 table tickets are released as a whole table';
END $$;

-- G1 ---------------------------------------------------------------------------
DO $$
DECLARE l_nina uuid; l_staff uuid;
BEGIN
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a1',true);   -- scanner
  BEGIN
    PERFORM public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e1','Door list');
    RAISE EXCEPTION 'G1: scanner created a list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a0',true);   -- owner
  l_nina := public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e1','Nina''s list',5,
                                          'c9000000-0000-0000-0000-0000000000b1',false,2);
  l_staff := public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e1','Staff comps');
  ASSERT (SELECT owner_uid FROM public.exos_guest_lists WHERE id=l_staff) = 'c9000000-0000-0000-0000-0000000000a0', 'G1: staff list owned by its creator';
  ASSERT (SELECT owner_uid IS NULL AND promoter_id='c9000000-0000-0000-0000-0000000000b1' FROM public.exos_guest_lists WHERE id=l_nina),
         'G1: promoter list owned by the promoter';
  ASSERT NOT (SELECT counts_toward_capacity FROM public.exos_guest_lists WHERE id=l_staff), 'G1: counts toward capacity defaults off';
  BEGIN
    PERFORM public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e1','Bad',NULL,NULL,false,5,NULL,'open',NULL,
                                          'c9000000-0000-0000-0000-0000000000a1');
    RAISE EXCEPTION 'G1: a scanner was made a list owner';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  PERFORM public.exos_add_guest(l_staff, 'Dana Staff', 'Dana@X.com', '+1 212 555 0100', 1, 'bar manager');
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a5',true);   -- content member, not the owner
  BEGIN
    PERFORM public.exos_add_guest(l_staff, 'Sneaky');
    RAISE EXCEPTION 'G1: a non-owner content member added to a list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  G1 lists are made by owner/manager; owners are members or promoters';
END $$;

-- G2 / G3 ------------------------------------------------------------------------
SELECT set_config('app.uid','',true);
DO $$
DECLARE tok_n uuid; tok_o uuid; l_nina uuid; l_staff uuid; e_eve uuid; kit jsonb;
BEGIN
  SELECT kit_token INTO tok_n FROM public.exos_promoters WHERE code='nina';
  SELECT kit_token INTO tok_o FROM public.exos_promoters WHERE code='omar';
  SELECT id INTO l_nina FROM public.exos_guest_lists WHERE name='Nina''s list';
  SELECT id INTO l_staff FROM public.exos_guest_lists WHERE name='Staff comps';
  PERFORM public.exos_promoter_add_guest(tok_n, l_nina, 'Ana Ruiz', 2);
  BEGIN
    PERFORM public.exos_promoter_add_guest(tok_n, l_nina, 'Ben Lee', 3);
    RAISE EXCEPTION 'G2: plus-ones above the list limit';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_promoter_add_guest(tok_n, l_nina, 'Ben Lee', 2);   -- 3 + 3 = 6 > 5
    RAISE EXCEPTION 'G2: cap exceeded';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  PERFORM public.exos_promoter_add_guest(tok_n, l_nina, 'Ben Lee', 1);     -- 5 of 5
  BEGIN
    PERFORM public.exos_promoter_add_guest(tok_n, l_nina, 'Cleo', 0);
    RAISE EXCEPTION 'G2: added to a full list';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  G2 cap (heads) and plus-one limit enforced';

  BEGIN
    PERFORM public.exos_promoter_add_guest(tok_n, l_staff, 'Crash', 0);
    RAISE EXCEPTION 'G3: promoter added to a staff list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_promoter_add_guest(tok_o, l_nina, 'Crash', 0);
    RAISE EXCEPTION 'G3: another promoter added to Nina''s list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_promoter_add_guest(gen_random_uuid(), l_nina, 'Crash', 0);
    RAISE EXCEPTION 'G3: a made-up token added a guest';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  SELECT id INTO e_eve FROM public.exos_guest_list_entries WHERE guest_name='Dana Staff';
  BEGIN
    PERFORM public.exos_promoter_remove_guest(tok_n, e_eve);
    RAISE EXCEPTION 'G3: promoter removed a guest from a staff list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  kit := public.exos_promoter_guest_lists(tok_n);
  ASSERT jsonb_array_length(kit) = 1 AND (kit->0->>'heads')::int = 5 AND jsonb_array_length(kit->0->'entries') = 2,
         'G3: the portal shows only Nina''s list, got ' || kit::text;
  ASSERT jsonb_array_length(public.exos_promoter_guest_lists(tok_o)) = 0, 'G3: Omar has no lists';
  -- Pausing the promoter closes their list to them.
  UPDATE public.exos_promoters SET status='paused' WHERE code='nina';
  BEGIN
    PERFORM public.exos_promoter_add_guest(tok_n, l_nina, 'Late', 0);
    RAISE EXCEPTION 'G3: a paused promoter added a guest';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  UPDATE public.exos_promoters SET status='active' WHERE code='nina';
  RAISE NOTICE 'OK  G3 promoters add only to their own open list';
END $$;

-- G4 ---------------------------------------------------------------------------
SELECT set_config('app.uid','c9000000-0000-0000-0000-0000000000a1',true);   -- scanner
DO $$
DECLARE ana uuid; ben uuid; r jsonb; ref uuid := gen_random_uuid();
BEGIN
  SELECT id INTO ana FROM public.exos_guest_list_entries WHERE guest_name='Ana Ruiz';
  SELECT id INTO ben FROM public.exos_guest_list_entries WHERE guest_name='Ben Lee';
  r := public.exos_guest_check_in(ana, 1, 'c9000000-0000-0000-0000-0000000000e1', ref);
  ASSERT (r->>'ok')::boolean AND (r->>'arrived')::int = 1 AND (r->>'party')::int = 3, 'G4: Ana arrives, got ' || r::text;
  r := public.exos_guest_check_in(ana, 1, 'c9000000-0000-0000-0000-0000000000e1', ref, 'offline-sync');
  ASSERT r->>'reason' = 'duplicate' AND (r->>'arrived')::int = 1, 'G4: replay of the same ref does not count twice';
  r := public.exos_guest_check_in(ana, 3, 'c9000000-0000-0000-0000-0000000000e1', gen_random_uuid());
  ASSERT NOT (r->>'ok')::boolean AND r->>'reason' = 'over' AND (r->>'remaining')::int = 2, 'G4: can''t exceed the party, got ' || r::text;
  r := public.exos_guest_check_in(ana, 2, 'c9000000-0000-0000-0000-0000000000e1', gen_random_uuid());
  ASSERT (r->>'ok')::boolean AND (r->>'arrived')::int = 3, 'G4: plus-ones arrive later';
  r := public.exos_guest_check_in(ana, 1, 'c9000000-0000-0000-0000-0000000000e1', gen_random_uuid());
  ASSERT r->>'reason' = 'used', 'G4: whole party already in';
  r := public.exos_guest_check_in(ben, 1, 'c9000000-0000-0000-0000-0000000000e3', gen_random_uuid());
  ASSERT r->>'reason' = 'wrong-event', 'G4: wrong event';
  ASSERT (SELECT arrived_at IS NOT NULL FROM public.exos_guest_list_entries WHERE id=ana), 'G4: arrived_at stamped';
  ASSERT (SELECT sum(count) FROM public.exos_guest_list_checkins WHERE entry_id=ana) = 3, 'G4: log adds up';
  RAISE NOTICE 'OK  G4 partial arrivals, no overshoot, idempotent offline replay';
END $$;

-- G5 ---------------------------------------------------------------------------
DO $$
DECLARE ben uuid; x jsonb; b1 uuid;
BEGIN
  SELECT id INTO ben FROM public.exos_guest_list_entries WHERE guest_name='Ben Lee';
  BEGIN
    PERFORM public.exos_update_guest(ben, 'Ben Lee', NULL, NULL, 0);
    RAISE EXCEPTION 'G5: scanner edited a guest';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_remove_guest(ben);
    RAISE EXCEPTION 'G5: scanner removed a guest';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_add_guest((SELECT list_id FROM public.exos_guest_list_entries WHERE id=ben), 'Friend');
    RAISE EXCEPTION 'G5: scanner added a guest';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  x := public.exos_event_door_extras('c9000000-0000-0000-0000-0000000000e1');
  ASSERT jsonb_array_length(x->'guests') = 3 AND jsonb_array_length(x->'lists') = 2, 'G5: door download has every guest + list';
  ASSERT position('dana@x.com' in lower(x::text)) = 0 AND position('555' in x::text) = 0, 'G5: no contact data at the door';
  SELECT id INTO b1 FROM public.exos_table_bookings WHERE order_ref='c9-t1';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(x->'tables') t
                  WHERE t->>'label' = 'Table 12' AND (t->>'min_spend_cents')::int = 60000
                    AND jsonb_array_length(t->'ticket_ids') = 4), 'G5: door sees table label + min spend by ticket';
  RAISE NOTICE 'OK  G5 scanner checks in, reads the door roster, cannot edit lists';
END $$;
-- RLS: as the authenticated role the scanner reads no list rows; the owner reads them.
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries) = 0, 'G5: scanner has no direct read of guest rows';
  ASSERT (SELECT count(*) FROM public.exos_table_bookings) = 0, 'G5: scanner has no direct read of bookings';
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a0',true);
  ASSERT (SELECT count(*) FROM public.exos_guest_list_entries WHERE event_id='c9000000-0000-0000-0000-0000000000e1') = 3, 'G5: owner reads guest rows';
  PERFORM set_config('app.uid','c9000000-0000-0000-0000-0000000000a2',true);
  ASSERT (SELECT count(*) FROM public.exos_table_bookings WHERE status = 'active') = 1, 'G5: a host reads their own booking';
  RAISE NOTICE 'OK  G5 RLS on guest rows and bookings';
END $$;
RESET ROLE;

-- G6 ---------------------------------------------------------------------------
SELECT set_config('app.uid','c9000000-0000-0000-0000-0000000000a4',true);   -- stranger
DO $$
DECLARE ben uuid;
BEGIN
  SELECT id INTO ben FROM public.exos_guest_list_entries WHERE guest_name='Ben Lee';
  BEGIN
    PERFORM public.exos_guest_check_in(ben, 1, 'c9000000-0000-0000-0000-0000000000e1', NULL);
    RAISE EXCEPTION 'G6: stranger checked a guest in';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_event_door_extras('c9000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'G6: stranger downloaded the door roster';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e1','Mine');
    RAISE EXCEPTION 'G6: stranger made a list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
SELECT set_config('app.uid','',true);
SET LOCAL ROLE anon;
DO $$
DECLARE ok boolean;
BEGIN
  BEGIN
    PERFORM public.exos_guest_check_in(gen_random_uuid(), 1, 'c9000000-0000-0000-0000-0000000000e1', NULL);
    RAISE EXCEPTION 'G6: anon may call guest check-in';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_event_door_extras('c9000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'G6: anon may call the door roster';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_add_guest(gen_random_uuid(), 'x');
    RAISE EXCEPTION 'G6: anon may call add_guest';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_assign_table(gen_random_uuid(), 'x');
    RAISE EXCEPTION 'G6: anon may call assign_table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_guest_list_entries;
    RAISE EXCEPTION 'G6: anon reads guest rows';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- The public table facts and the promoter portal are anon-callable.
  ASSERT (SELECT count(*) FROM public.exos_public_table_tiers('c9000000-0000-0000-0000-0000000000e1')) = 3, 'G6: public table tiers';
  ASSERT (SELECT min_spend_cents FROM public.exos_public_table_tiers('c9000000-0000-0000-0000-0000000000e1')
           WHERE tier_id='c9000000-0000-0000-0000-0000000000d1') = 60000, 'G6: min spend is public';
  RAISE NOTICE 'OK  G6 non-staff and anon blocked; public table info open';
END $$;
RESET ROLE;

-- G7 ---------------------------------------------------------------------------
SELECT set_config('app.uid','c9000000-0000-0000-0000-0000000000a0',true);
DO $$
DECLARE l uuid; g uuid; l_off uuid;
BEGIN
  l := public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e3','Counts',NULL,NULL,true);
  l_off := public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e3','Free list');
  PERFORM public.exos_add_guest(l_off, 'Off Cap', NULL, NULL, 5);
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='c9000000-0000-0000-0000-0000000000e3') = 0, 'G7: default list is off-inventory';
  g := public.exos_add_guest(l, 'Counted', NULL, NULL, 1);
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='c9000000-0000-0000-0000-0000000000e3') = 2, 'G7: counting list takes 2 heads';
  BEGIN
    PERFORM public.exos_add_guest(l, 'Too many', NULL, NULL, 1);
    RAISE EXCEPTION 'G7: counting list went past the house cap';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e3','Counts',NULL,NULL,false,5,l);
    RAISE EXCEPTION 'G7: flag flipped on a non-empty list';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  PERFORM public.exos_remove_guest(g);
  ASSERT (SELECT tickets_sold FROM public.exos_events WHERE id='c9000000-0000-0000-0000-0000000000e3') = 0, 'G7: removal gives heads back';
  RAISE NOTICE 'OK  G7 counts-toward-capacity (default off) uses the house cap';
END $$;

-- G8 ---------------------------------------------------------------------------
DO $$
DECLARE ana uuid; l_nina uuid;
BEGIN
  SELECT id, list_id INTO ana, l_nina FROM public.exos_guest_list_entries WHERE guest_name='Ana Ruiz';
  BEGIN
    PERFORM public.exos_remove_guest(ana);
    RAISE EXCEPTION 'G8: removed a guest who arrived';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_update_guest(ana, 'Ana Ruiz', NULL, NULL, 1);
    RAISE EXCEPTION 'G8: plus-ones cut below arrivals';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_upsert_guest_list('c9000000-0000-0000-0000-0000000000e1','Nina''s list',4,
                                          'c9000000-0000-0000-0000-0000000000b1',false,2,l_nina);
    RAISE EXCEPTION 'G8: cap lowered below heads';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_delete_guest_list(l_nina);
    RAISE EXCEPTION 'G8: deleted a list with arrivals';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  RAISE NOTICE 'OK  G8 edits never contradict arrivals';
END $$;

ROLLBACK;
