-- ============================================================================
-- Organizer refunds of table orders (mig 20260926080000, on top of
-- 20260926040000 organizer refunds + 20260926050000 tables). Self-contained:
-- own fixtures (c8…), one transaction, rolled back.
--   R1 refunding a whole table order frees exactly 1 table and party_size
--      people (quota + event total); the booking is cancelled
--   R2 replaying the finalize is a no-op
--   R3 a per-ticket refund of one table ticket frees that person's seat but
--      not the table; refunding the rest then frees the table exactly once
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c8000000-0000-0000-0000-0000000000a0','c8owner@x.com',now()),
  ('c8000000-0000-0000-0000-0000000000b1','c8buyer@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c8000000-0000-0000-0000-000000000001','C8 Club','c8-club','c8000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c8000000-0000-0000-0000-000000000001','c8000000-0000-0000-0000-0000000000a0','owner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold) VALUES
  ('c8000000-0000-0000-0000-0000000000e1','c8000000-0000-0000-0000-000000000001','C8 Night','c8-night','published',
   now() + interval '3 days',0,0);
-- Table for 3, $300 deposit, 4 tables, inside a 12-person room quota.
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,kind,party_size) VALUES
  ('c8000000-0000-0000-0000-0000000000d1','c8000000-0000-0000-0000-0000000000e1','VIP table',300,4,0,'table',3);
INSERT INTO public.exos_quotas(id,event_id,org_id,name,size) VALUES
  ('c8000000-0000-0000-0000-0000000000f1','c8000000-0000-0000-0000-0000000000e1','c8000000-0000-0000-0000-000000000001','Room',12);
INSERT INTO public.exos_quota_tiers(quota_id,tier_id) VALUES
  ('c8000000-0000-0000-0000-0000000000f1','c8000000-0000-0000-0000-0000000000d1');

INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent) VALUES
  ('cs_c8a','c8000000-0000-0000-0000-0000000000e1','c8000000-0000-0000-0000-0000000000d1','c8000000-0000-0000-0000-000000000001',
   'c8000000-0000-0000-0000-0000000000b1','c8buyer@x.com',1,30000,'pending','pi_c8a'),
  ('cs_c8b','c8000000-0000-0000-0000-0000000000e1','c8000000-0000-0000-0000-0000000000d1','c8000000-0000-0000-0000-000000000001',
   'c8000000-0000-0000-0000-0000000000b1','c8buyer@x.com',1,30000,'pending','pi_c8b');
SELECT array_length(public.exos_fulfill_checkout('cs_c8a'),1) AS a_tickets, array_length(public.exos_fulfill_checkout('cs_c8b'),1) AS b_tickets;
SELECT public.exos_record_payment('cs_c8a','pi_c8a',30000,'succeeded');
SELECT public.exos_record_payment('cs_c8b','pi_c8b',30000,'succeeded');

CREATE OR REPLACE FUNCTION pg_temp.c8_sold() RETURNS int LANGUAGE sql AS
  $$ SELECT sold FROM public.exos_ticket_tiers WHERE id='c8000000-0000-0000-0000-0000000000d1' $$;
CREATE OR REPLACE FUNCTION pg_temp.c8_house() RETURNS int LANGUAGE sql AS
  $$ SELECT tickets_sold FROM public.exos_events WHERE id='c8000000-0000-0000-0000-0000000000e1' $$;
CREATE OR REPLACE FUNCTION pg_temp.c8_quota() RETURNS int LANGUAGE sql AS
  $$ SELECT public.exos_quota_available('c8000000-0000-0000-0000-0000000000f1') $$;

DO $$
BEGIN
  ASSERT pg_temp.c8_sold() = 2 AND pg_temp.c8_house() = 6 AND pg_temp.c8_quota() = 6,
         format('setup: 2 tables / 6 people sold, 6 quota left; got %s / %s / %s', pg_temp.c8_sold(), pg_temp.c8_house(), pg_temp.c8_quota());
  RAISE NOTICE 'OK  setup: two paid tables of 3';
END $$;

-- R1 / R2 --------------------------------------------------------------------
DO $$
DECLARE c jsonb; f jsonb; rid uuid;
BEGIN
  c := public.exos_refund_claim('c8000000-0000-0000-0000-0000000000a0','cs_c8a','nonce-c8-whole',NULL,NULL,true,'cancelled table');
  rid := (c->>'request_id')::uuid;
  f := public.exos_refund_finalize(rid, 're_c8a', 'succeeded');
  ASSERT (f->>'changed')::boolean, 'R1: finalize applied';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='cs_c8a' AND status='voided') = 3, 'R1: all 3 tickets voided';
  ASSERT pg_temp.c8_sold() = 1, 'R1: exactly one table back on sale, sold = ' || pg_temp.c8_sold();
  ASSERT pg_temp.c8_house() = 3, 'R1: party_size people off the event total, got ' || pg_temp.c8_house();
  ASSERT pg_temp.c8_quota() = 9, 'R1: party_size seats back in the quota, got ' || pg_temp.c8_quota();
  ASSERT (SELECT status FROM public.exos_table_bookings WHERE order_ref='cs_c8a') = 'cancelled', 'R1: booking cancelled';
  RAISE NOTICE 'OK  R1 whole-order refund frees 1 table + party_size people';

  -- R2: Stripe webhook replays the same answer; a direct full-refund replay too.
  f := public.exos_refund_finalize(rid, 're_c8a', 'succeeded');
  ASSERT NOT (f->>'changed')::boolean, 'R2: replayed finalize is a no-op';
  PERFORM public.exos_refund_checkout('cs_c8a', 'refunded');
  ASSERT pg_temp.c8_sold() = 1 AND pg_temp.c8_house() = 3 AND pg_temp.c8_quota() = 9, 'R2: counters unchanged by replays';
  RAISE NOTICE 'OK  R2 replay is a no-op';
END $$;

-- R3 ---------------------------------------------------------------------------
DO $$
DECLARE c jsonb; f jsonb; t1 uuid;
BEGIN
  SELECT ticket_ids[1] INTO t1 FROM public.exos_table_bookings WHERE order_ref='cs_c8b';
  c := public.exos_refund_claim('c8000000-0000-0000-0000-0000000000a0','cs_c8b','nonce-c8-one',
                                jsonb_build_array(jsonb_build_object('ticket_id', t1)),NULL,false,'one guest out');
  f := public.exos_refund_finalize((c->>'request_id')::uuid, 're_c8b1', 'succeeded');
  ASSERT (SELECT status FROM public.exos_tickets WHERE id=t1) = 'voided', 'R3: the refunded ticket is voided';
  ASSERT pg_temp.c8_sold() = 1, 'R3: a per-ticket refund must not free the table, sold = ' || pg_temp.c8_sold();
  ASSERT (SELECT status FROM public.exos_table_bookings WHERE order_ref='cs_c8b') = 'active', 'R3: booking stays active';
  ASSERT pg_temp.c8_house() = 2 AND pg_temp.c8_quota() = 10, 'R3: that one person''s seat is freed';
  RAISE NOTICE 'OK  R3a partial per-ticket refund keeps the table sold';

  -- The rest of the order: now the table goes back, once.
  c := public.exos_refund_claim('c8000000-0000-0000-0000-0000000000a0','cs_c8b','nonce-c8-rest',NULL,NULL,true,'rest');
  f := public.exos_refund_finalize((c->>'request_id')::uuid, 're_c8b2', 'succeeded');
  ASSERT pg_temp.c8_sold() = 0, 'R3: table freed once when its last ticket is refunded, sold = ' || pg_temp.c8_sold();
  ASSERT pg_temp.c8_house() = 0 AND pg_temp.c8_quota() = 12, 'R3: all seats back';
  ASSERT (SELECT status FROM public.exos_table_bookings WHERE order_ref='cs_c8b') = 'cancelled', 'R3: booking cancelled';
  f := public.exos_refund_finalize((c->>'request_id')::uuid, 're_c8b2', 'succeeded');
  ASSERT pg_temp.c8_sold() = 0 AND pg_temp.c8_house() = 0, 'R3: replay no-op';
  RAISE NOTICE 'OK  R3b refunding the rest frees the table exactly once';
END $$;

ROLLBACK;
