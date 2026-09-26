-- ============================================================================
-- Organizer-initiated refunds (mig 20260926040000). The Stripe call lives in
-- the exos-refund edge function; every money decision is one of these RPCs,
-- called here in the order the function (and stripe-webhook) calls them.
-- Self-contained: own org "of" (owner …a1, manager …a2, finance …a3,
-- scanner …a4, content …a5, stranger …a6, disabled owner …a7).
-- Run after the full chain (growth_base / run_p0.sh) + the migration.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('0f000000-0000-0000-0000-0000000000a1','ofown@x.com',now()),
  ('0f000000-0000-0000-0000-0000000000a2','ofmgr@x.com',now()),
  ('0f000000-0000-0000-0000-0000000000a3','offin@x.com',now()),
  ('0f000000-0000-0000-0000-0000000000a4','ofscan@x.com',now()),
  ('0f000000-0000-0000-0000-0000000000a5','ofcontent@x.com',now()),
  ('0f000000-0000-0000-0000-0000000000a6','ofstranger@x.com',now()),
  ('0f000000-0000-0000-0000-0000000000a7','ofdisabled@x.com',now()),
  ('0f000000-0000-0000-0000-0000000000b1','ofbuyer@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('0f000000-0000-0000-0000-000000000001','OF Org','of-org-stub','0f000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role,disabled) VALUES
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a1','owner',false),
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a2','manager',false),
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a3','finance',false),
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a4','scanner',false),
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a5','content',false),
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a7','owner',true);
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,total_tickets,tickets_sold,created_by) VALUES
  ('0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-000000000001','OF Night','of-night-stub','published',
   now() + interval '3 days', 100, 9, '0f000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('0f000000-0000-0000-0000-0000000000d1','0f000000-0000-0000-0000-0000000000e1','GA',30,100,9,'public');
INSERT INTO public.exos_event_addons(id,event_id,name,price,capacity,sold) VALUES
  ('0f000000-0000-0000-0000-0000000000ad','0f000000-0000-0000-0000-0000000000e1','Poster',10,50,1);

-- Orders: O1 3 tickets + a $10 add-on for $100.01 (ticket part 9001 -> 3001/3000/3000);
-- O2 2 tickets for $50; O3 2 tickets for $40; O4 2 tickets for $60; O5 free-claim style (no PI).
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent,addons) VALUES
  ('cs_of1','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000d1','0f000000-0000-0000-0000-000000000001',
   '0f000000-0000-0000-0000-0000000000b1','ofbuyer@x.com',3,10001,'fulfilled','pi_of1',
   '[{"addon_id":"0f000000-0000-0000-0000-0000000000ad","quantity":1,"unit_price_cents":1000,"name":"Poster"}]'),
  ('cs_of2','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000d1','0f000000-0000-0000-0000-000000000001',
   '0f000000-0000-0000-0000-0000000000b1','ofbuyer@x.com',2,5000,'fulfilled','pi_of2',NULL),
  ('cs_of3','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000d1','0f000000-0000-0000-0000-000000000001',
   '0f000000-0000-0000-0000-0000000000b1','ofbuyer@x.com',2,4000,'fulfilled','pi_of3',NULL),
  ('cs_of4','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000d1','0f000000-0000-0000-0000-000000000001',
   '0f000000-0000-0000-0000-0000000000b1','ofbuyer@x.com',2,6000,'fulfilled',NULL,NULL),
  ('cs_of5','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000d1','0f000000-0000-0000-0000-000000000001',
   '0f000000-0000-0000-0000-0000000000b1','ofbuyer@x.com',0,0,'fulfilled',NULL,NULL);
SELECT public.exos_record_payment('cs_of1','pi_of1',10001,'succeeded');
SELECT public.exos_record_payment('cs_of2','pi_of2',5000,'succeeded');
SELECT public.exos_record_payment('cs_of3','pi_of3',4000,'succeeded');
SELECT public.exos_record_payment('cs_of4','pi_of4',6000,'succeeded');   -- PI only in the ledger

INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref,created_at)
SELECT ('0f000000-0000-0000-0000-0000000' || o || '0' || lpad(n::text, 3, '0'))::uuid,
       '0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000d1',
       '0f000000-0000-0000-0000-0000000000b1','0f000000-0000-0000-0000-0000000000b1','active', gen_random_uuid()::text, 0,
       'cs_of' || o, now() - interval '1 hour' + n * interval '1 second'
  FROM (VALUES (1,1),(1,2),(1,3),(2,1),(2,2),(3,1),(3,2),(4,1),(4,2)) v(o,n);
INSERT INTO public.exos_order_addons(event_id,org_id,addon_id,addon_name,buyer_id,owner_id,quantity,unit_price_paid,order_ref,status)
  VALUES ('0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000ad','Poster',
          '0f000000-0000-0000-0000-0000000000b1','0f000000-0000-0000-0000-0000000000b1',1,10,'cs_of1','active');

-- Helper: what the edge function does after Stripe answers (claim -> refund -> finalize).
CREATE FUNCTION pg_temp.req_id(j jsonb) RETURNS uuid LANGUAGE sql AS $$ SELECT (j->>'request_id')::uuid $$;

-- ---------------------------------------------------------------------------
-- M1. Refundable math: per-ticket shares split the ticket part in cents.
-- ---------------------------------------------------------------------------
SELECT set_config('app.uid','0f000000-0000-0000-0000-0000000000a3',false);   -- finance can preview
DO $$
DECLARE p jsonb; shares int[];
BEGIN
  p := public.exos_refund_preview('cs_of1');
  SELECT array_agg((t->>'share_cents')::int ORDER BY t->>'ticket_id') INTO shares FROM jsonb_array_elements(p->'tickets') t;
  ASSERT (p->>'refundable_cents')::int = 10001, 'M1: whole order refundable, got ' || p::text;
  ASSERT shares = ARRAY[3001,3000,3000], 'M1: shares 3001/3000/3000, got ' || shares::text;
  ASSERT (SELECT sum((t->>'refundable_cents')::int) FROM jsonb_array_elements(p->'tickets') t) = 9001, 'M1: ticket part 9001';
  p := public.exos_refund_preview('cs_of5');
  ASSERT (p->>'refundable_cents')::int = 0 AND (p->>'has_payment')::boolean = false, 'M1: free order has nothing to refund';
  p := public.exos_refund_preview('cs_of4');
  ASSERT (p->>'refundable_cents')::int = 6000, 'M1: PI found through the ledger';
  RAISE NOTICE 'OK  M1 refundable math (shares, free order, ledger PI)';
END $$;

-- ---------------------------------------------------------------------------
-- M2. Partial on a ticket, then the rest of it: void only when covered in full.
-- ---------------------------------------------------------------------------
DO $$
DECLARE c jsonb; f jsonb; p jsonb; v_status text; v_sold int;
BEGIN
  c := public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of1','nonce-m2-partial',
         '[{"ticket_id":"0f000000-0000-0000-0000-000000010001","amount_cents":1000}]'::jsonb, NULL, false, 'goodwill');
  ASSERT (c->>'amount_cents')::int = 1000 AND c->>'payment_intent' = 'pi_of1' AND c->>'status' = 'claimed', 'M2: claim ' || c::text;
  ASSERT c->>'idempotency_key' = 'exos_refund_' || (c->>'request_id'), 'M2: idempotency key from request id';
  f := public.exos_refund_finalize(pg_temp.req_id(c), 're_of_m2a', 'succeeded');
  ASSERT (f->>'voided')::int = 0, 'M2: a partial ticket refund voids nothing';
  SELECT status INTO v_status FROM public.exos_tickets WHERE id='0f000000-0000-0000-0000-000000010001';
  ASSERT v_status = 'active', 'M2: ticket still valid';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id='cs_of1') = 'partially_refunded', 'M2: session partially_refunded';
  ASSERT (SELECT count(*) FROM public.exos_order_refunds WHERE refund_id='re_of_m2a' AND amount_cents=1000 AND is_partial) = 1, 'M2: ledger row';
  p := public.exos_refund_preview('cs_of1');
  ASSERT (p->>'refundable_cents')::int = 9001, 'M2: 9001 left on the order';
  ASSERT (SELECT (t->>'refundable_cents')::int FROM jsonb_array_elements(p->'tickets') t
           WHERE t->>'ticket_id'='0f000000-0000-0000-0000-000000010001') = 2001, 'M2: 2001 left on the ticket';

  -- The rest of the ticket (amount omitted = what's left).
  c := public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of1','nonce-m2-rest',
         '[{"ticket_id":"0f000000-0000-0000-0000-000000010001"}]'::jsonb);
  ASSERT (c->>'amount_cents')::int = 2001, 'M2: rest of the ticket is 2001, got ' || c::text;
  f := public.exos_refund_finalize(pg_temp.req_id(c), 're_of_m2b', 'succeeded');
  ASSERT (f->>'voided')::int = 1, 'M2: fully refunded ticket voided';
  SELECT status INTO v_status FROM public.exos_tickets WHERE id='0f000000-0000-0000-0000-000000010001';
  SELECT sold INTO v_sold FROM public.exos_ticket_tiers WHERE id='0f000000-0000-0000-0000-0000000000d1';
  ASSERT v_status = 'voided' AND v_sold = 8, 'M2: voided + inventory freed (sold 9 -> 8), got ' || v_status || '/' || v_sold;
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='cs_of1' AND status='active') = 2, 'M2: other tickets untouched';
  RAISE NOTICE 'OK  M2 partial then full on a ticket; void only when covered';
END $$;

-- ---------------------------------------------------------------------------
-- M3. Can't exceed: per ticket, per order, bad input.
-- ---------------------------------------------------------------------------
DO $$
DECLARE ok boolean;
BEGIN
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of1','nonce-m3-a',
      '[{"ticket_id":"0f000000-0000-0000-0000-000000010002","amount_cents":3001}]'::jsonb);
    RAISE EXCEPTION 'M3: over-refunded a ticket';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of1','nonce-m3-b', NULL, 9002);
    RAISE EXCEPTION 'M3: over-refunded the order';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of1','nonce-m3-c',
      '[{"ticket_id":"0f000000-0000-0000-0000-000000010001"}]'::jsonb);
    RAISE EXCEPTION 'M3: refunded an already fully refunded ticket';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of1','nonce-m3-d',
      '[{"ticket_id":"0f000000-0000-0000-0000-000000020001"}]'::jsonb);
    RAISE EXCEPTION 'M3: refunded a ticket from another order';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of1','nonce-m3-e', NULL, 0);
    RAISE EXCEPTION 'M3: zero refund accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of5','nonce-m3-f', NULL, NULL, true);
    RAISE EXCEPTION 'M3: refunded an order with no payment';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of1','short', NULL, 100);
    RAISE EXCEPTION 'M3: accepted a bad nonce';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  ASSERT (SELECT count(*) FROM public.exos_refund_requests WHERE nonce LIKE 'nonce-m3-%') = 0, 'M3: nothing reserved';
  RAISE NOTICE 'OK  M3 refunds cannot exceed what is left';
END $$;

-- ---------------------------------------------------------------------------
-- M4. Two outstanding claims can't add up to more than was paid; a failed
--     Stripe call releases its reservation. Nonce retries return the same row.
-- ---------------------------------------------------------------------------
DO $$
DECLARE a jsonb; b jsonb; a2 jsonb;
BEGIN
  a := public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a1','cs_of2','nonce-m4-a', NULL, 3000);
  -- Not finalized yet (Stripe call in flight). A second claim sees the reservation.
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a2','cs_of2','nonce-m4-b', NULL, 3000);
    RAISE EXCEPTION 'M4: two claims over-refunded the order';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  b := public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a2','cs_of2','nonce-m4-b', NULL, 2000);
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a2','cs_of2','nonce-m4-c', NULL, NULL, true);
    RAISE EXCEPTION 'M4: whole-order claim on a fully reserved order';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  -- Retry of the same click: same request back, nothing new reserved.
  a2 := public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a1','cs_of2','nonce-m4-a', NULL, 3000);
  ASSERT a2->>'request_id' = a->>'request_id' AND (a2->>'existing')::boolean, 'M4: nonce retry returns the same request';
  ASSERT (SELECT count(*) FROM public.exos_refund_requests WHERE session_id='cs_of2') = 2, 'M4: two requests only';
  -- Stripe refused A: release it; B's 2000 + a new 3000 now fit exactly.
  PERFORM public.exos_refund_finalize(pg_temp.req_id(a), NULL, 'failed', 'card_declined');
  ASSERT (SELECT status FROM public.exos_refund_requests WHERE id=pg_temp.req_id(a)) = 'failed', 'M4: A failed';
  PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a2','cs_of2','nonce-m4-d', NULL, 3000);
  RAISE NOTICE 'OK  M4 concurrent claims cannot over-refund; failure releases';
END $$;

-- ---------------------------------------------------------------------------
-- M5. Webhook replay of the same refund doesn't double-record or re-void;
--     a dashboard refund (ledger only) lowers what's refundable.
-- ---------------------------------------------------------------------------
DO $$
DECLARE c jsonb; f jsonb; v_left int;
BEGIN
  c := public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a1','cs_of3','nonce-m5',
         '[{"ticket_id":"0f000000-0000-0000-0000-000000030001"}]'::jsonb);
  PERFORM public.exos_refund_finalize(pg_temp.req_id(c), 're_of_m5', 'pending');
  ASSERT (SELECT status FROM public.exos_tickets WHERE id='0f000000-0000-0000-0000-000000030001') = 'voided', 'M5: void once Stripe accepts';
  -- stripe-webhook charge.refunded: record every refund on the PI by id, then finalize by metadata. Twice.
  FOR i IN 1..2 LOOP
    PERFORM public.exos_record_refund('cs_of3','re_of_m5',2000,'succeeded','pi_of3','requested_by_customer','usd','evt_'||i);
    f := public.exos_refund_finalize(pg_temp.req_id(c), 're_of_m5', 'succeeded');
  END LOOP;
  ASSERT (SELECT count(*) FROM public.exos_order_refunds WHERE session_id='cs_of3') = 1, 'M5: one ledger row';
  ASSERT (f->>'changed')::boolean = false, 'M5: second finalize is a no-op';
  ASSERT (SELECT status FROM public.exos_refund_requests WHERE id=pg_temp.req_id(c)) = 'succeeded', 'M5: pending -> succeeded';
  ASSERT (SELECT sold FROM public.exos_ticket_tiers WHERE id='0f000000-0000-0000-0000-0000000000d1') = 7, 'M5: sold decremented once';
  -- A late 'pending' after 'succeeded' doesn't move it back.
  PERFORM public.exos_refund_finalize(pg_temp.req_id(c), 're_of_m5', 'pending');
  ASSERT (SELECT status FROM public.exos_refund_requests WHERE id=pg_temp.req_id(c)) = 'succeeded', 'M5: no downgrade';
  v_left := (public.exos_refund_preview('cs_of3')->>'refundable_cents')::int;
  ASSERT v_left = 2000, 'M5: 2000 left, got ' || v_left;
  -- Dashboard refund of 500 arrives via the webhook only.
  PERFORM public.exos_record_refund('cs_of3','re_of_dash',500,'succeeded','pi_of3','dashboard');
  v_left := (public.exos_refund_preview('cs_of3')->>'refundable_cents')::int;
  ASSERT v_left = 1500, 'M5: dashboard refund counted, got ' || v_left;
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a1','cs_of3','nonce-m5-x', NULL, 1501);
    RAISE EXCEPTION 'M5: refunded past a dashboard refund';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  -- Refund id can't be re-pointed at another request.
  BEGIN
    PERFORM public.exos_refund_finalize(pg_temp.req_id(c), 're_other', 'succeeded');
    RAISE EXCEPTION 'M5: request re-tied to another refund';
  EXCEPTION WHEN raise_exception THEN NULL; END;
  RAISE NOTICE 'OK  M5 webhook replay idempotent; dashboard refunds count';
END $$;

-- ---------------------------------------------------------------------------
-- M6. Whole order: everything still refundable, all tickets + add-ons voided;
--     the webhook's full-refund path afterwards changes nothing.
-- ---------------------------------------------------------------------------
DO $$
DECLARE c jsonb; f jsonb; v_sold int; v_ev int;
BEGIN
  c := public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a2','cs_of1','nonce-m6', NULL, NULL, true, 'event moved');
  ASSERT (c->>'amount_cents')::int = 7000, 'M6: 10001 - 3001 already refunded = 7000, got ' || c::text;
  f := public.exos_refund_finalize(pg_temp.req_id(c), 're_of_m6', 'succeeded');
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='cs_of1' AND status='active') = 0, 'M6: all voided';
  ASSERT (SELECT status FROM public.exos_order_addons WHERE order_ref='cs_of1') = 'refunded', 'M6: add-on refunded';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id='cs_of1') = 'refunded', 'M6: session refunded';
  SELECT sold INTO v_sold FROM public.exos_ticket_tiers WHERE id='0f000000-0000-0000-0000-0000000000d1';
  ASSERT v_sold = 5, 'M6: sold 7 -> 5, got ' || v_sold;
  -- Webhook charge.refunded (charge now fully refunded): void + record, replayed.
  PERFORM public.exos_refund_checkout('cs_of1','stripe refund');
  PERFORM public.exos_record_refund('cs_of1','re_of_m6',7000,'succeeded','pi_of1','requested_by_customer');
  SELECT sold INTO v_sold FROM public.exos_ticket_tiers WHERE id='0f000000-0000-0000-0000-0000000000d1';
  ASSERT v_sold = 5, 'M6: webhook replay did not double-decrement';
  ASSERT (public.exos_refund_preview('cs_of1')->>'refundable_cents')::int = 0, 'M6: nothing left';
  BEGIN
    PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a2','cs_of1','nonce-m6-x', NULL, 1);
    RAISE EXCEPTION 'M6: refunded a fully refunded order';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  RAISE NOTICE 'OK  M6 whole-order refund voids everything; webhook replay no-op';
END $$;

-- ---------------------------------------------------------------------------
-- M7. Event cancel listing: only orders with money left, paged by cursor.
-- ---------------------------------------------------------------------------
DO $$
DECLARE ids text[]; c jsonb;
BEGIN
  SELECT array_agg(session_id ORDER BY session_id) INTO ids
    FROM public.exos_refund_event_orders_svc('0f000000-0000-0000-0000-000000000003'::uuid, '0f000000-0000-0000-0000-0000000000e1');
  RAISE EXCEPTION 'M7: unknown actor listed orders';
EXCEPTION WHEN insufficient_privilege THEN
  SELECT array_agg(session_id ORDER BY session_id) INTO ids
    FROM public.exos_refund_event_orders_svc('0f000000-0000-0000-0000-0000000000a1', '0f000000-0000-0000-0000-0000000000e1');
  ASSERT ids = ARRAY['cs_of3','cs_of4'], 'M7: cs_of1 empty, cs_of2 fully reserved, cs_of5 free; got ' || coalesce(ids::text,'null');
  SELECT array_agg(session_id) INTO ids
    FROM public.exos_refund_event_orders_svc('0f000000-0000-0000-0000-0000000000a1', '0f000000-0000-0000-0000-0000000000e1', 'cs_of3');
  ASSERT ids = ARRAY['cs_of4'], 'M7: cursor pages';
  c := public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a1','cs_of4','evc:batch1:cs_of4', NULL, NULL, true, 'event cancelled', 'event_cancel');
  ASSERT c->>'scope' = 'event_cancel' AND (c->>'amount_cents')::int = 6000 AND c->>'payment_intent' = 'pi_of4', 'M7: cancel claim ' || c::text;
  PERFORM public.exos_refund_finalize(pg_temp.req_id(c), 're_of_m7', 'succeeded');
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='cs_of4' AND status='active') = 0, 'M7: cancel voids';
  RAISE NOTICE 'OK  M7 event-cancel listing + claim';
END $$;

-- ---------------------------------------------------------------------------
-- M8. Roles: owner / manager / finance can; scanner, content, strangers and
--     disabled members can't (claim and preview).
-- ---------------------------------------------------------------------------
DO $$
DECLARE u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['0f000000-0000-0000-0000-0000000000a4','0f000000-0000-0000-0000-0000000000a5',
                           '0f000000-0000-0000-0000-0000000000a6','0f000000-0000-0000-0000-0000000000a7'] LOOP
    BEGIN
      PERFORM public.exos_refund_claim(u::uuid,'cs_of3','nonce-m8-' || right(u, 2), NULL, 100);
      RAISE EXCEPTION 'M8: % could claim a refund', u;
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    PERFORM set_config('app.uid', u, false);
    BEGIN
      PERFORM public.exos_refund_preview('cs_of3');
      RAISE EXCEPTION 'M8: % could preview', u;
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    BEGIN
      PERFORM * FROM public.exos_event_refund_orders('0f000000-0000-0000-0000-0000000000e1');
      RAISE EXCEPTION 'M8: % could list orders', u;
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  END LOOP;
  BEGIN
    PERFORM public.exos_refund_claim(NULL,'cs_of3','nonce-m8-null', NULL, 100);
    RAISE EXCEPTION 'M8: null actor claimed';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM set_config('app.uid', '0f000000-0000-0000-0000-0000000000a3', false);
  ASSERT (SELECT count(*) FROM public.exos_event_refund_orders('0f000000-0000-0000-0000-0000000000e1')) = 4, 'M8: finance lists the paid orders';
  PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a3','cs_of3','nonce-m8-fin', NULL, 100);
  RAISE NOTICE 'OK  M8 role checks (finance yes; scanner/content/stranger/disabled no)';
END $$;

-- ---------------------------------------------------------------------------
-- M9. Grants: anon gets nothing; authenticated can't call the service RPCs or
--     write the tables directly; finance reads its org's requests via RLS.
-- ---------------------------------------------------------------------------
SET LOCAL ROLE anon;
DO $$
BEGIN
  BEGIN PERFORM public.exos_refund_preview('cs_of3'); RAISE EXCEPTION 'M9: anon preview';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM public.exos_event_refund_orders('0f000000-0000-0000-0000-0000000000e1'); RAISE EXCEPTION 'M9: anon list';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM 1 FROM public.exos_refund_requests; RAISE EXCEPTION 'M9: anon read requests';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a1','cs_of3','nonce-m9-anon', NULL, 1);
    RAISE EXCEPTION 'M9: anon claim';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM set_config('app.uid', '0f000000-0000-0000-0000-0000000000a1', false);
  BEGIN PERFORM public.exos_refund_claim('0f000000-0000-0000-0000-0000000000a1','cs_of3','nonce-m9-auth', NULL, 1);
    RAISE EXCEPTION 'M9: authenticated called the service claim';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.exos_refund_finalize(gen_random_uuid(), 're_x', 'succeeded');
    RAISE EXCEPTION 'M9: authenticated called finalize';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.exos_refund_ticket_state('cs_of3');
    RAISE EXCEPTION 'M9: helper is client-callable';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    INSERT INTO public.exos_refund_requests(session_id,org_id,scope,amount_cents,nonce)
      VALUES ('cs_of3','0f000000-0000-0000-0000-000000000001','order',1,'nonce-m9-direct');
    RAISE EXCEPTION 'M9: direct insert';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  ASSERT (SELECT count(*) FROM public.exos_refund_requests WHERE session_id='cs_of3') >= 2, 'M9: owner reads its requests';
  ASSERT (public.exos_refund_preview('cs_of3')->>'refundable_cents')::int = 1400, 'M9: owner preview via authenticated';
  PERFORM set_config('app.uid', '0f000000-0000-0000-0000-0000000000a4', false);
  ASSERT (SELECT count(*) FROM public.exos_refund_requests) = 0, 'M9: scanner reads no requests';
END $$;
RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'OK  M9 grants (anon none; service RPCs + helpers closed; RLS read)'; END $$;

ROLLBACK;
