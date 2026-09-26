-- ============================================================================
-- Money-path refund/auto-refund contract test (for the stripe-webhook rewrite).
--
-- The webhook orchestration itself is Deno/TS and can't run here, but every
-- money decision it makes is a call into these DB RPCs. This test exercises the
-- exact call SEQUENCES the webhook issues, and asserts the resulting money state
-- — so the contracts the webhook relies on are pinned:
--
--   A. Auto-refund of a settled-but-unfulfillable order reconciles to 'refunded'.
--   B. A PARTIAL refund records + flags is_partial + sets 'partially_refunded'
--      and does NOT touch tickets (webhook withholds the void — validated here as
--      "record_refund alone leaves tickets active").
--   C. A FULL refund (record_refund + exos_refund_checkout) voids every ticket and
--      frees inventory.
--   D. Replay of the full-refund event is idempotent (no double void, no dup row).
--   E. A dispute void invalidates the order's tickets.
--
-- Run: bash tests/exos/run_money_path.sh   (applies prereq + the two real
--      migrations these RPCs live in, then this file).
-- ============================================================================
\set ON_ERROR_STOP on

-- Seed: org, event, tier, buyer.
INSERT INTO auth.users(id,email,email_confirmed_at)
  VALUES ('00000000-0000-0000-0000-000000000001','buyer@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid)
  VALUES ('aaaa0000-0000-0000-0000-000000000001','OrgA','orga','00000000-0000-0000-0000-000000000001');
INSERT INTO public.exos_events(id,org_id,name,slug,status,total_tickets,tickets_sold)
  VALUES ('eeee0000-0000-0000-0000-000000000001','aaaa0000-0000-0000-0000-000000000001','EvtA','evta','published',100,10);
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold)
  VALUES ('dddd0000-0000-0000-0000-000000000001','eeee0000-0000-0000-0000-000000000001','GA',50,100,10);

-- Helper to mint N active tickets against a session (mirrors exos_fulfill_checkout's insert).
CREATE OR REPLACE FUNCTION pg_temp.mint(p_session text, p_n int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE i int;
BEGIN
  FOR i IN 1..p_n LOOP
    INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret,order_ref)
    VALUES ('eeee0000-0000-0000-0000-000000000001','aaaa0000-0000-0000-0000-000000000001',
            'dddd0000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001',
            '00000000-0000-0000-0000-000000000001','active', gen_random_uuid()::text, p_session);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- A. Auto-refund of a settled-but-unfulfillable order.
--    Webhook seq on a 'failed' session: record_payment(succeeded) -> Stripe
--    refund -> record_refund(full). Assert it reconciles to 'refunded'.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,failure_reason,payment_intent)
  VALUES ('cs_A','eeee0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000001',
          'aaaa0000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','buyer@x.com',
          1,5000,'failed','tier sold out at fulfillment','pi_A');
SELECT public.exos_record_payment('cs_A','pi_A',5000,'succeeded');
SELECT public.exos_record_refund('cs_A','re_A',5000,'succeeded','pi_A','auto-refund: unfulfillable after payment');
DO $$
DECLARE v_status text; v_partial boolean; v_tickets int;
BEGIN
  SELECT status INTO v_status FROM public.exos_checkout_sessions WHERE session_id='cs_A';
  SELECT is_partial INTO v_partial FROM public.exos_order_refunds WHERE refund_id='re_A';
  SELECT count(*) INTO v_tickets FROM public.exos_tickets WHERE order_ref='cs_A';
  ASSERT v_status = 'refunded', 'A: failed+full-refund should reconcile to refunded, got '||v_status;
  ASSERT v_partial = false,     'A: full refund must not be flagged partial';
  ASSERT v_tickets = 0,         'A: unfulfillable session minted no tickets';
  RAISE NOTICE 'OK  A auto-refund of unfulfillable order -> refunded';
END $$;

-- ---------------------------------------------------------------------------
-- B. PARTIAL refund: record only (webhook withholds the void). Tickets stay.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent)
  VALUES ('cs_B','eeee0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000001',
          'aaaa0000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','buyer@x.com',4,10000,'fulfilled','pi_B');
SELECT pg_temp.mint('cs_B',4);
SELECT public.exos_record_payment('cs_B','pi_B',10000,'succeeded');
SELECT public.exos_record_refund('cs_B','re_B',2500,'succeeded','pi_B','partial');
DO $$
DECLARE v_status text; v_partial boolean; v_active int;
BEGIN
  SELECT status INTO v_status FROM public.exos_checkout_sessions WHERE session_id='cs_B';
  SELECT is_partial INTO v_partial FROM public.exos_order_refunds WHERE refund_id='re_B';
  SELECT count(*) INTO v_active FROM public.exos_tickets WHERE order_ref='cs_B' AND status='active';
  ASSERT v_status = 'partially_refunded', 'B: 2500 of 10000 should be partially_refunded, got '||v_status;
  ASSERT v_partial = true,                'B: refund must be flagged partial';
  ASSERT v_active = 4,                    'B: a PARTIAL refund must NOT void tickets (got '||v_active||' active)';
  RAISE NOTICE 'OK  B partial refund records, does not void the order';
END $$;

-- ---------------------------------------------------------------------------
-- C. FULL refund: record_refund + exos_refund_checkout -> void all + free stock.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent)
  VALUES ('cs_C','eeee0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000001',
          'aaaa0000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','buyer@x.com',4,10000,'fulfilled','pi_C');
SELECT pg_temp.mint('cs_C',4);
SELECT public.exos_record_payment('cs_C','pi_C',10000,'succeeded');
-- Webhook order for a FULL refund: void FIRST, then record (see webhook comment).
SELECT public.exos_refund_checkout('cs_C','stripe refund');
SELECT public.exos_record_refund('cs_C','re_C',10000,'succeeded','pi_C','full');
DO $$
DECLARE v_status text; v_active int; v_sold int;
BEGIN
  SELECT status INTO v_status FROM public.exos_checkout_sessions WHERE session_id='cs_C';
  SELECT count(*) INTO v_active FROM public.exos_tickets WHERE order_ref='cs_C' AND status='active';
  SELECT sold INTO v_sold FROM public.exos_ticket_tiers WHERE id='dddd0000-0000-0000-0000-000000000001';
  ASSERT v_status = 'refunded', 'C: full refund should be refunded, got '||v_status;
  ASSERT v_active = 0,          'C: full refund must void all tickets (got '||v_active||' active)';
  ASSERT v_sold = 6,            'C: tier sold should drop 10 -> 6 after voiding 4, got '||v_sold;
  RAISE NOTICE 'OK  C full refund voids all tickets + frees inventory';
END $$;

-- ---------------------------------------------------------------------------
-- D. Replay the full-refund event: idempotent (no dup refund row, no re-void).
-- ---------------------------------------------------------------------------
SELECT public.exos_refund_checkout('cs_C','stripe refund');                       -- already refunded -> 0
SELECT public.exos_record_refund('cs_C','re_C',10000,'succeeded','pi_C','full'); -- same refund_id -> upsert
DO $$
DECLARE v_refunds int; v_active int; v_sold int;
BEGIN
  SELECT count(*) INTO v_refunds FROM public.exos_order_refunds WHERE session_id='cs_C';
  SELECT count(*) INTO v_active  FROM public.exos_tickets WHERE order_ref='cs_C' AND status='active';
  SELECT sold INTO v_sold FROM public.exos_ticket_tiers WHERE id='dddd0000-0000-0000-0000-000000000001';
  ASSERT v_refunds = 1, 'D: replay must not duplicate the refund row (got '||v_refunds||')';
  ASSERT v_active = 0,  'D: replay must not change tickets';
  ASSERT v_sold = 6,    'D: replay must not double-decrement inventory, got '||v_sold;
  RAISE NOTICE 'OK  D full-refund replay is idempotent';
END $$;

-- ---------------------------------------------------------------------------
-- E. Dispute (chargeback): void the order's tickets so entry is invalidated.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent)
  VALUES ('cs_E','eeee0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000001',
          'aaaa0000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','buyer@x.com',2,4000,'fulfilled','pi_E');
SELECT pg_temp.mint('cs_E',2);
SELECT public.exos_refund_checkout('cs_E','chargeback dispute (fraudulent)');
DO $$
DECLARE v_status text; v_active int;
BEGIN
  SELECT status INTO v_status FROM public.exos_checkout_sessions WHERE session_id='cs_E';
  SELECT count(*) INTO v_active FROM public.exos_tickets WHERE order_ref='cs_E' AND status='active';
  ASSERT v_status = 'refunded', 'E: dispute void should set refunded, got '||v_status;
  ASSERT v_active = 0,          'E: dispute must void the order tickets (got '||v_active||' active)';
  RAISE NOTICE 'OK  E dispute void invalidates order tickets';
END $$;

-- ---------------------------------------------------------------------------
-- F. P0 (mig 20260924205115): partial refunds recorded by id, then the rest.
--    $20 + $15 on a $50 order must stay 'partially_refunded' with tickets live;
--    and a session already mis-marked 'refunded' (the pre-fix double count)
--    must still void its tickets when the full refund arrives.
-- ---------------------------------------------------------------------------
INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,payment_intent)
  VALUES ('cs_F','eeee0000-0000-0000-0000-000000000001','dddd0000-0000-0000-0000-000000000001',
          'aaaa0000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','buyer@x.com',
          2,5000,'fulfilled','pi_F');
SELECT pg_temp.mint('cs_F', 2);
SELECT public.exos_record_payment('cs_F','pi_F',5000,'succeeded');
SELECT public.exos_record_refund('cs_F','re_F1',2000,'succeeded','pi_F');
SELECT public.exos_record_refund('cs_F','re_F2',1500,'succeeded','pi_F');
SELECT public.exos_record_refund('cs_F','re_F2',1500,'succeeded','pi_F');  -- webhook retry
DO $$
DECLARE v_status text; v_active int; v_rows int;
BEGIN
  SELECT status INTO v_status FROM public.exos_checkout_sessions WHERE session_id='cs_F';
  SELECT count(*) INTO v_active FROM public.exos_tickets WHERE order_ref='cs_F' AND status='active';
  SELECT count(*) INTO v_rows FROM public.exos_order_refunds WHERE session_id='cs_F';
  ASSERT v_status = 'partially_refunded', format('F: $35 of $50 must be partially_refunded, got %s', v_status);
  ASSERT v_active = 2, 'F: partial refunds must not void tickets';
  ASSERT v_rows = 2, 'F: a retried refund id must not add a row';

  -- Simulate the pre-fix state: the old NULL-id double count flipped the
  -- session to 'refunded' while tickets stayed active.
  UPDATE public.exos_checkout_sessions SET status='refunded' WHERE session_id='cs_F';
  PERFORM public.exos_record_refund('cs_F','re_F3',1500,'succeeded','pi_F');
  PERFORM public.exos_refund_checkout('cs_F','stripe refund');
  SELECT count(*) INTO v_active FROM public.exos_tickets WHERE order_ref='cs_F' AND status='active';
  ASSERT v_active = 0, 'F: a full refund must void the tickets even if the session was already marked refunded';
  RAISE NOTICE 'OK  F partial-then-full refund voids (incl. a mis-marked session)';
END $$;

-- ---------------------------------------------------------------------------
-- G. A NULL refund id is refused (it can't be deduplicated).
-- ---------------------------------------------------------------------------
DO $$
DECLARE raised boolean := false;
BEGIN
  BEGIN
    PERFORM public.exos_record_refund('cs_F', NULL, 5000, 'succeeded', 'pi_F');
  EXCEPTION WHEN raise_exception THEN raised := true;
  END;
  ASSERT raised, 'G: exos_record_refund must refuse a NULL refund id';
  RAISE NOTICE 'OK  G NULL refund id refused';
END $$;

SELECT '*** money-path refund contracts: ALL ASSERTIONS PASSED ***' AS result;
