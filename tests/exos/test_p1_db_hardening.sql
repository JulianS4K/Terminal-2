-- ============================================================================
-- P1 database hardening (mig 20260925021000), the parts the stub schema has:
-- check-in, voucher re-validation at fulfillment, comps (uniform answers and
-- the budget). The org/event read narrowing and invite claims need prod's RLS
-- and invites table; they're tested on a copy of prod's real schema.
-- Self-contained: own org p1 (owner …a1), scanner …a3, holder …a4.
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('f7000000-0000-0000-0000-0000000000a1','p1own@x.com',now()),
  ('f7000000-0000-0000-0000-0000000000a3','p1scan@x.com',now()),
  ('f7000000-0000-0000-0000-0000000000a4','p1hold@x.com',now()),
  ('f7000000-0000-0000-0000-0000000000a5','p1has@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('f7000000-0000-0000-0000-000000000001','P1 Org','p1-org-stub','f7000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-0000000000a1','owner'),
  ('f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-0000000000a3','scanner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,doors_at,total_tickets,created_by) VALUES
  ('f7000000-0000-0000-0000-0000000000e1','f7000000-0000-0000-0000-000000000001','P1 Live','p1-live-stub','published',
   now() + interval '2 hours', now() - interval '1 hour', 0, 'f7000000-0000-0000-0000-0000000000a1'),
  ('f7000000-0000-0000-0000-0000000000e2','f7000000-0000-0000-0000-000000000001','P1 Off','p1-off-stub','cancelled',
   now() + interval '2 hours', now() - interval '1 hour', 0, 'f7000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('f7000000-0000-0000-0000-0000000000d1','f7000000-0000-0000-0000-0000000000e1','GA',25,100,0,'public'),
  ('f7000000-0000-0000-0000-0000000000d2','f7000000-0000-0000-0000-0000000000e1','Guest',0,100,0,'public');
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref)
SELECT ('f7000000-0000-0000-0000-00000000c00' || n)::uuid,
       CASE WHEN n = 7 THEN 'f7000000-0000-0000-0000-0000000000e2'::uuid ELSE 'f7000000-0000-0000-0000-0000000000e1'::uuid END,
       'f7000000-0000-0000-0000-000000000001','f7000000-0000-0000-0000-0000000000a4','f7000000-0000-0000-0000-0000000000a4',
       'active','sek',25,'p1-seed-' || n
  FROM generate_series(1, 7) n;

-- P1. Check-in: event required, cancelled refused, barcodes always verified,
--     verification derived server-side.
DO $$
DECLARE
  e1 uuid := 'f7000000-0000-0000-0000-0000000000e1';
  e2 uuid := 'f7000000-0000-0000-0000-0000000000e2';
  own uuid := 'f7000000-0000-0000-0000-0000000000a4';
  bkt bigint := floor(extract(epoch FROM now()) * 1000 / 30000);
  k4 text; k5 text;
BEGIN
  k4 := 'T-f7000000-0000-0000-0000-00000000c004:' || own || ':' || bkt || ':' ||
        rtrim(translate(encode(extensions.hmac('f7000000-0000-0000-0000-00000000c004:' || own || ':' || bkt, 'sek', 'sha256'), 'base64'), '+/', '-_'), '=');
  k5 := 'T-f7000000-0000-0000-0000-00000000c005:' || own || ':' || bkt || ':' ||
        rtrim(translate(encode(extensions.hmac('f7000000-0000-0000-0000-00000000c005:' || own || ':' || bkt, 'sek', 'sha256'), 'base64'), '+/', '-_'), '=');
  PERFORM set_config('app.uid', 'f7000000-0000-0000-0000-0000000000a3', false);
  PERFORM set_config('app.jwt', '{"email":"p1scan@x.com"}', false);
  ASSERT public.exos_check_in_ticket('f7000000-0000-0000-0000-00000000c001','manual','verified',NULL,NULL) ->> 'reason' = 'wrong-event',
         'P1: no event id is refused';
  ASSERT public.exos_check_in_ticket('f7000000-0000-0000-0000-00000000c001','manual','verified',NULL,e1) ->> 'reason' = 'checked-in',
         'P1: manual override admits';
  ASSERT public.exos_check_in_ticket('f7000000-0000-0000-0000-00000000c002','manual','manual',
           'T-f7000000-0000-0000-0000-00000000c002:x:1:forged',e1) ->> 'reason' = 'barcode-rejected', 'P1: forged payload rejected (manual)';
  ASSERT public.exos_check_in_ticket('f7000000-0000-0000-0000-00000000c003','manual','manual',
           'f7000000-0000-0000-0000-00000000c003:' || own || ':1',e1) ->> 'reason' = 'barcode-rejected', 'P1: legacy payload rejected (manual)';
  ASSERT public.exos_check_in_ticket('f7000000-0000-0000-0000-00000000c004','manual','manual',k4,e1) ->> 'reason' = 'checked-in',
         'P1: valid signed payload typed in';
  ASSERT public.exos_check_in_ticket('f7000000-0000-0000-0000-00000000c005','camera','legacy',k5,e1) ->> 'reason' = 'checked-in',
         'P1: valid camera scan';
  ASSERT public.exos_check_in_ticket('f7000000-0000-0000-0000-00000000c006','camera','verified',NULL,e1) ->> 'reason' = 'barcode-rejected',
         'P1: camera without payload rejected';
  ASSERT public.exos_check_in_ticket('f7000000-0000-0000-0000-00000000c007','manual','manual',NULL,e2) ->> 'reason' = 'event-cancelled',
         'P1: cancelled event refused';
  ASSERT (SELECT verification || '/' || source FROM public.exos_event_checkins WHERE ticket_id = 'f7000000-0000-0000-0000-00000000c001') = 'manual/manual',
         'P1: client "verified" without a barcode logged as manual';
  ASSERT (SELECT verification || '/' || source FROM public.exos_event_checkins WHERE ticket_id = 'f7000000-0000-0000-0000-00000000c004') = 'verified/manual',
         'P1: HMAC-checked manual entry logged verified';
  ASSERT (SELECT verification || '/' || source FROM public.exos_event_checkins WHERE ticket_id = 'f7000000-0000-0000-0000-00000000c005') = 'verified/camera',
         'P1: camera scan logged verified/camera';
  RAISE NOTICE 'OK  P1 check-in hardening';
END $$;

-- P2. Fulfillment re-validates the voucher (all-or-nothing on a miss).
DO $$
DECLARE e1 uuid := 'f7000000-0000-0000-0000-0000000000e1'; org uuid := 'f7000000-0000-0000-0000-000000000001';
BEGIN
  INSERT INTO public.exos_vouchers(id,event_id,code,tier_id,max_uses,used_count,bypass_capacity,reserved_email,valid_until) VALUES
    ('f7000000-0000-0000-0000-0000000000f1',e1,'P1RES',NULL,5,0,false,'p1hold@x.com',NULL),
    ('f7000000-0000-0000-0000-0000000000f2',e1,'P1EXP',NULL,5,0,false,NULL,now() - interval '1 minute'),
    ('f7000000-0000-0000-0000-0000000000f3',e1,'P1TIER','f7000000-0000-0000-0000-0000000000d2',5,0,false,NULL,NULL),
    ('f7000000-0000-0000-0000-0000000000f4',e1,'P1OK',NULL,5,0,false,'p1hold@x.com',now() + interval '1 day');
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,voucher_id) VALUES
    ('p1-cs1',e1,'f7000000-0000-0000-0000-0000000000d1',org,'f7000000-0000-0000-0000-0000000000a4','other@x.com',1,2500,'pending','f7000000-0000-0000-0000-0000000000f1'),
    ('p1-cs2',e1,'f7000000-0000-0000-0000-0000000000d1',org,'f7000000-0000-0000-0000-0000000000a4','p1hold@x.com',1,2500,'pending','f7000000-0000-0000-0000-0000000000f2'),
    ('p1-cs3',e1,'f7000000-0000-0000-0000-0000000000d1',org,'f7000000-0000-0000-0000-0000000000a4','p1hold@x.com',1,2500,'pending','f7000000-0000-0000-0000-0000000000f3'),
    ('p1-cs4',e1,'f7000000-0000-0000-0000-0000000000d1',org,'f7000000-0000-0000-0000-0000000000a4','p1hold@x.com',1,2500,'pending','f7000000-0000-0000-0000-0000000000f4');
  ASSERT public.exos_fulfill_checkout('p1-cs1') = '{}'::uuid[], 'P2: reserved for another email';
  ASSERT public.exos_fulfill_checkout('p1-cs2') = '{}'::uuid[], 'P2: expired';
  ASSERT public.exos_fulfill_checkout('p1-cs3') = '{}'::uuid[], 'P2: other tier';
  ASSERT array_length(public.exos_fulfill_checkout('p1-cs4'), 1) = 1, 'P2: valid voucher fulfills';
  ASSERT (SELECT count(*) FROM public.exos_checkout_sessions WHERE session_id IN ('p1-cs1','p1-cs2','p1-cs3')
           AND status = 'failed' AND failure_reason LIKE 'voucher%') = 3, 'P2: failed with the voucher reason';
  ASSERT (SELECT sum(used_count) FROM public.exos_vouchers WHERE id IN ('f7000000-0000-0000-0000-0000000000f1',
           'f7000000-0000-0000-0000-0000000000f2','f7000000-0000-0000-0000-0000000000f3')) = 0, 'P2: nothing consumed on a miss';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'order-failed' AND to_email = 'other@x.com'
           AND html LIKE '%access code you used%') = 1, 'P2: failure mail names the access code';
  RAISE NOTICE 'OK  P2 voucher re-validated at fulfillment';
END $$;

-- P3. Comps: same answer with or without an account; budget in every free mint.
DO $$
DECLARE
  e1 uuid := 'f7000000-0000-0000-0000-0000000000e1'; org uuid := 'f7000000-0000-0000-0000-000000000001';
  guest uuid := 'f7000000-0000-0000-0000-0000000000d2';
  ids uuid[]; used0 int; err text;
BEGIN
  PERFORM set_config('app.uid', 'f7000000-0000-0000-0000-0000000000a1', false);
  PERFORM set_config('app.jwt', '{"email":"p1own@x.com"}', false);
  ids := public.exos_issue_ticket_to_email(e1, guest, 'p1nobody@x.com', 1);
  ASSERT array_length(ids, 1) = 1, 'P3: no-account recipient answered like any other';
  ASSERT (SELECT count(*) FROM public.exos_transfers WHERE receiver_email = 'p1nobody@x.com' AND status = 'pending') = 1,
         'P3: no-account recipient gets a claim-by-email transfer';
  ids := public.exos_issue_ticket_to_email(e1, guest, 'p1has@x.com', 1);
  ASSERT (SELECT owner_id FROM public.exos_tickets WHERE id = ids[1]) = 'f7000000-0000-0000-0000-0000000000a5', 'P3: account holder owns it';
  ASSERT (SELECT array_agg(DISTINCT outcome) FROM public.exos_issue_comp_batch(e1, guest, ARRAY['p1nobody2@x.com','p1has@x.com'], 1))
         = ARRAY['issued'], 'P3: batch outcome does not reveal accounts';

  used0 := public.exos_org_comp_usage(org);
  PERFORM public.exos_set_org_comp_budget(org, used0 + 1);
  BEGIN
    PERFORM public.exos_mint_tickets(e1, guest, 2);
    RAISE EXCEPTION 'P3: free mint over budget should fail';
  EXCEPTION WHEN check_violation THEN err := SQLERRM;
  END;
  ASSERT err LIKE '%comp budget exceeded%', 'P3: mint refused by budget';
  ids := public.exos_mint_tickets(e1, guest, 1, 'p1-mint');
  ASSERT (SELECT channel_source FROM public.exos_tickets WHERE id = ids[1]) = 'boxoffice', 'P3: free mint recorded as box office';
  ASSERT public.exos_org_comp_usage(org) = used0 + 1, 'P3: free mint counts as a comp';
  err := NULL;
  BEGIN
    PERFORM public.exos_issue_ticket_to_email(e1, guest, 'p1has@x.com', 1);
  EXCEPTION WHEN check_violation THEN err := SQLERRM;
  END;
  ASSERT err LIKE '%comp budget exceeded%', 'P3: issue-to-email refused by budget';
  ids := public.exos_mint_tickets(e1, 'f7000000-0000-0000-0000-0000000000d1', 1, 'p1-paid', 25);
  ASSERT (SELECT channel_source FROM public.exos_tickets WHERE id = ids[1]) = 'vibepass', 'P3: paid mint is not a comp';

  PERFORM set_config('app.uid', 'f7000000-0000-0000-0000-0000000000a4', false);
  PERFORM set_config('app.jwt', '{"email":"p1hold@x.com"}', false);
  ids := public.exos_claim_free_tickets(e1, guest, 1, NULL, 'comp', 'p1-free');
  ASSERT (SELECT channel_source FROM public.exos_tickets WHERE id = ids[1]) = 'vibepass', 'P3: buyer cannot label a free claim a comp';
  RAISE NOTICE 'OK  P3 comps: uniform answers, budget enforced';
END $$;
