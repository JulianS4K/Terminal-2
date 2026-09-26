-- ============================================================================
-- Paid checkout keeps promoter attribution (mig 20260924223000). Runs after
-- test_fulfill_all_or_nothing.sql in the same DB; fixtures reuse its f1 org.
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES
  ('f1000000-0000-0000-0000-0000000000d9','f1000000-0000-0000-0000-0000000000e1','Promo GA',20,10,0);

-- P1. A paid session with a promoter mints tickets credited to that promoter.
DO $$
DECLARE ids uuid[];
BEGIN
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,
                                           quantity,amount_cents,status,promoter_id,attribution)
  VALUES ('f1-p1','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d9',
          'f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-00000000000b','f1buyer@x.com',
          2,4000,'pending','dj-kay','{"utm_source":"instagram","utm_medium":"story"}');
  ids := public.exos_fulfill_checkout('f1-p1');
  ASSERT array_length(ids,1) = 2, 'P1: order fulfills';
  ASSERT (SELECT count(*) FROM public.exos_tickets WHERE order_ref='f1-p1' AND promoter_id='dj-kay') = 2,
         'P1: every ticket carries the promoter';
  RAISE NOTICE 'OK  P1 paid tickets carry the promoter';
END $$;

-- P2. No promoter → tickets have none (and nothing else changes).
DO $$
DECLARE ids uuid[];
BEGIN
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status)
  VALUES ('f1-p2','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d9',
          'f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-00000000000b','f1buyer@x.com',1,2000,'pending');
  ids := public.exos_fulfill_checkout('f1-p2');
  ASSERT array_length(ids,1) = 1 AND
         (SELECT promoter_id FROM public.exos_tickets WHERE order_ref='f1-p2') IS NULL, 'P2: no promoter';
  RAISE NOTICE 'OK  P2 unattributed order unchanged';
END $$;

-- P3. The table refuses a malformed promoter code.
DO $$
BEGIN
  BEGIN
    INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,quantity,amount_cents,status,promoter_id)
    VALUES ('f1-p3','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000d9',
            'f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-00000000000b',1,2000,'pending','<script>');
    RAISE EXCEPTION 'P3: bad promoter code was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  P3 malformed promoter code refused';
END $$;
