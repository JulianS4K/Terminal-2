-- ============================================================================
-- Fan referral rewards (mig 20260926030000). Self-contained: builds its own
-- org / events / fans (a7… ids) inside a transaction and rolls back.
--   owner  a7…0a   finance a7…0f   stranger a7…05
--   fan A  a7…a1 (fana@x.com, confirmed)   fan U a7…a2 (unconfirmed)
--   friends B1..B9 a7…b1..b9
--   E1 (reward rule, every 2, max 2, free T2), E0 earlier, E2 later.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('a7000000-0000-0000-0000-00000000000a','rrowner@x.com',now()),
  ('a7000000-0000-0000-0000-00000000000f','rrfinance@x.com',now()),
  ('a7000000-0000-0000-0000-000000000005','rrstranger@x.com',now()),
  ('a7000000-0000-0000-0000-0000000000a1','fana@x.com',now()),
  ('a7000000-0000-0000-0000-0000000000a2','fanu@x.com',NULL),
  ('a7000000-0000-0000-0000-0000000000a3','fana2@x.com',now()),
  ('a7000000-0000-0000-0000-0000000000ac','FanA@X.com',now());   -- A's second account, same email
INSERT INTO auth.users(id,email,email_confirmed_at)
  SELECT ('a7000000-0000-0000-0000-0000000000b' || g)::uuid, 'friend' || g || '@y.com', now() FROM generate_series(1,9) g;

INSERT INTO public.exos_orgs(id,name,slug) VALUES ('a7000000-0000-0000-0000-000000000001','RR Org','rr-org');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-00000000000a','owner'),
  ('a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-00000000000f','finance');
INSERT INTO public.exos_events(id,org_id,name,status,starts_at) VALUES
  ('a7000000-0000-0000-0000-0000000000e0','a7000000-0000-0000-0000-000000000001','RR Earlier','published',now()+interval '2 days'),
  ('a7000000-0000-0000-0000-0000000000e1','a7000000-0000-0000-0000-000000000001','RR Night','published',now()+interval '10 days'),
  ('a7000000-0000-0000-0000-0000000000e2','a7000000-0000-0000-0000-000000000001','RR Later','published',now()+interval '30 days');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,visibility) VALUES
  ('a7000000-0000-0000-0000-0000000000d0','a7000000-0000-0000-0000-0000000000e0','GA',20,0,'public'),
  ('a7000000-0000-0000-0000-0000000000d1','a7000000-0000-0000-0000-0000000000e1','GA',20,0,'public'),
  ('a7000000-0000-0000-0000-0000000000d2','a7000000-0000-0000-0000-0000000000e1','Friend reward',20,0,'hidden'),
  ('a7000000-0000-0000-0000-0000000000d3','a7000000-0000-0000-0000-0000000000e2','GA',40,0,'public');

-- Fans hold tickets (needed for a referral code).
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,buyer_email,status,price_paid,order_ref,barcode_secret) VALUES
  ('a7000000-0000-0000-0000-0000000000e1','a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000d1',
   'a7000000-0000-0000-0000-0000000000a1','a7000000-0000-0000-0000-0000000000a1','fana@x.com','active',20,'rr-a','s'),
  ('a7000000-0000-0000-0000-0000000000e1','a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000d1',
   'a7000000-0000-0000-0000-0000000000a2','a7000000-0000-0000-0000-0000000000a2','fanu@x.com','active',20,'rr-u','s'),
  ('a7000000-0000-0000-0000-0000000000e2','a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000d3',
   'a7000000-0000-0000-0000-0000000000a3','a7000000-0000-0000-0000-0000000000a3','fana2@x.com','active',40,'rr-a3','s');
UPDATE public.exos_tickets SET attendee_name = 'Uma' WHERE order_ref = 'rr-u';

SELECT set_config('app.uid','a7000000-0000-0000-0000-0000000000a1',false);
SELECT set_config('test.code_a', public.exos_my_referral_code('a7000000-0000-0000-0000-0000000000e1'), false);
SELECT set_config('app.uid','a7000000-0000-0000-0000-0000000000a2',false);
SELECT set_config('test.code_u', public.exos_my_referral_code('a7000000-0000-0000-0000-0000000000e1'), false);
SELECT set_config('app.uid','a7000000-0000-0000-0000-0000000000a3',false);
SELECT set_config('test.code_a3', public.exos_my_referral_code('a7000000-0000-0000-0000-0000000000e2'), false);

-- A friend buys one ticket through a code (what fulfillment / attach do).
CREATE FUNCTION pg_temp.rr_buy(p_code text, p_buyer int, p_price numeric DEFAULT 20, p_event text DEFAULT 'e1')
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,buyer_email,status,price_paid,order_ref,barcode_secret,referral_code)
  VALUES (('a7000000-0000-0000-0000-0000000000' || p_event)::uuid, 'a7000000-0000-0000-0000-000000000001',
          CASE WHEN p_event = 'e2' THEN 'a7000000-0000-0000-0000-0000000000d3'::uuid
               WHEN p_event = 'e0' THEN 'a7000000-0000-0000-0000-0000000000d0'::uuid ELSE 'a7000000-0000-0000-0000-0000000000d1'::uuid END,
          ('a7000000-0000-0000-0000-0000000000b' || p_buyer)::uuid, ('a7000000-0000-0000-0000-0000000000b' || p_buyer)::uuid,
          'friend' || p_buyer || '@y.com', 'active', p_price, 'rr-b' || p_buyer || '-' || gen_random_uuid(), 's', p_code)
  RETURNING id $$;
CREATE FUNCTION pg_temp.rr_vouchers(p_code text) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.exos_referral_rewards rr JOIN public.exos_vouchers v ON v.id = rr.voucher_id
   WHERE rr.referral_code = p_code $$;

-- RR1. Anonymous callers get nothing; internals aren't client-callable.
SELECT set_config('app.uid','',false);
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'exos_set_referral_reward_rule(uuid,uuid,boolean,int,int,boolean,uuid,uuid,text,int,boolean)',
    'exos_delete_referral_reward_rule(uuid)', 'exos_get_referral_reward_rule(uuid)',
    'exos_referral_leaderboard(uuid,int)', 'exos_my_referral_progress(uuid)',
    'exos_redeem_referral_reward(uuid,uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'), 'RR1: anon can execute ' || f;
    ASSERT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'), 'RR1: authenticated cannot execute ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['exos_referral_rewards_sync(text)', 'exos_rr_counted_tickets(text,boolean)',
    'exos_rr_tier_price(uuid)', 'exos_rr_mask_email(text)', 'exos_rr_effective_rule(uuid)',
    'exos_tg_referral_rewards()', 'exos_tg_referral_reward_deleted()'] LOOP
    ASSERT NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE')
       AND NOT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'), 'RR1: client can execute ' || f;
  END LOOP;
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_referral_rewards', 'SELECT')
     AND NOT has_table_privilege('anon', 'public.exos_referral_reward_rules', 'SELECT'), 'RR1: tables are RPC-only';
  BEGIN
    PERFORM public.exos_my_referral_progress('a7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'RR1: anon read progress';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'RR1: anon set a rule';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.exos_referral_leaderboard('a7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'RR1: anon read the leaderboard';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  RR1 anon blocked, internals not client-callable';
END $$;

-- RR2. Only owners / managers set rules (a fan, a stranger and finance can't).
DO $$
DECLARE u text;
BEGIN
  FOREACH u IN ARRAY ARRAY['a7000000-0000-0000-0000-0000000000a1','a7000000-0000-0000-0000-000000000005',
                           'a7000000-0000-0000-0000-00000000000f'] LOOP
    PERFORM set_config('app.uid', u, false);
    BEGIN
      PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1', NULL, true, 2, 2);
      RAISE EXCEPTION 'RR2: % set a rule', u;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      PERFORM public.exos_set_referral_reward_rule(NULL, 'a7000000-0000-0000-0000-000000000001', true, 2, 2);
      RAISE EXCEPTION 'RR2: % set an org default', u;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-0000000000a1',false);
  BEGIN
    PERFORM * FROM public.exos_referral_leaderboard('a7000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'RR2: a fan read the leaderboard';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_referral_reward_rules WHERE org_id = 'a7000000-0000-0000-0000-000000000001'),
         'RR2: no rule was written';
  RAISE NOTICE 'OK  RR2 non-staff cannot set rules';
END $$;

-- RR3. Owner validation, then the E1 rule: every 2 tickets, max 2, a free
--      ticket on the hidden "Friend reward" tier.
SELECT set_config('app.uid','a7000000-0000-0000-0000-00000000000a',false);
DO $$
BEGIN
  BEGIN   -- % off needs a tier
    PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1', NULL, true, 2, 2, true,
      NULL, NULL, 'percent_off', 50);
    RAISE EXCEPTION 'RR3: percent without tier accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN   -- reward on an earlier event
    PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1', NULL, true, 2, 2, true,
      'a7000000-0000-0000-0000-0000000000e0', 'a7000000-0000-0000-0000-0000000000d0', 'price', 0);
    RAISE EXCEPTION 'RR3: earlier reward event accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN   -- tier not on the reward event
    PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1', NULL, true, 2, 2, true,
      NULL, 'a7000000-0000-0000-0000-0000000000d3', 'price', 0);
    RAISE EXCEPTION 'RR3: foreign tier accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1', NULL, true, 0, 2);
    RAISE EXCEPTION 'RR3: every 0 accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1', NULL, true, 2, 2, true,
    NULL, 'a7000000-0000-0000-0000-0000000000d2', 'price', 0);
  ASSERT (SELECT count(*) FROM public.exos_referral_reward_rules WHERE event_id = 'a7000000-0000-0000-0000-0000000000e1') = 1,
         'RR3: one rule';
  ASSERT (public.exos_get_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1')->>'applies') = 'event', 'RR3: event rule applies';
  RAISE NOTICE 'OK  RR3 rule validation + save';
END $$;

-- RR4. Crossing the first threshold issues exactly one voucher, bound to A's email.
DO $$
DECLARE c text := current_setting('test.code_a'); v public.exos_vouchers%ROWTYPE; p jsonb;
BEGIN
  PERFORM pg_temp.rr_buy(c, 1);
  ASSERT pg_temp.rr_vouchers(c) = 0, 'RR4: nothing at 1 ticket';
  PERFORM pg_temp.rr_buy(c, 2);
  ASSERT pg_temp.rr_vouchers(c) = 1, 'RR4: one voucher at 2 tickets, got ' || pg_temp.rr_vouchers(c);
  SELECT v2.* INTO v FROM public.exos_vouchers v2 JOIN public.exos_referral_rewards rr ON rr.voucher_id = v2.id
   WHERE rr.referral_code = c AND rr.milestone = 1;
  ASSERT v.reserved_email = 'fana@x.com' AND v.tier_id = 'a7000000-0000-0000-0000-0000000000d2'
     AND v.price_override = 0 AND v.max_uses = 1 AND v.event_id = 'a7000000-0000-0000-0000-0000000000e1',
     'RR4: voucher shape ' || row_to_json(v)::text;
  ASSERT (SELECT is_valid FROM public.exos_check_voucher(v.event_id, v.code, 'fana@x.com')), 'RR4: A can use it';
  ASSERT NOT (SELECT is_valid FROM public.exos_check_voucher(v.event_id, v.code, 'friend1@y.com')), 'RR4: bound to A';
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-0000000000a1',false);
  p := public.exos_my_referral_progress('a7000000-0000-0000-0000-0000000000e1');
  ASSERT (p->>'counted')::int = 2 AND (p->>'nextThreshold')::int = 4
     AND jsonb_array_length(p->'rewards') = 1 AND p->'rewards'->0->>'code' = v.code
     AND (p->'rewards'->0->>'free')::boolean, 'RR4: progress ' || p::text;
  RAISE NOTICE 'OK  RR4 first threshold: one voucher, bound to the referrer';
END $$;

-- RR5. Self-referral doesn't count: same user, or another account / ticket
--      with the referrer's email.
DO $$
DECLARE c text := current_setting('test.code_a');
BEGIN
  INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,buyer_email,status,price_paid,order_ref,barcode_secret,referral_code) VALUES
    ('a7000000-0000-0000-0000-0000000000e1','a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000d1',
     'a7000000-0000-0000-0000-0000000000a1','a7000000-0000-0000-0000-0000000000a1','fana@x.com','active',20,'rr-self1','s',c),
    ('a7000000-0000-0000-0000-0000000000e1','a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000d1',
     'a7000000-0000-0000-0000-0000000000ac','a7000000-0000-0000-0000-0000000000ac',NULL,'active',20,'rr-self2','s',c),
    ('a7000000-0000-0000-0000-0000000000e1','a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000d1',
     NULL,NULL,'FANA@x.com','active',20,'rr-self3','s',c);
  ASSERT public.exos_rr_counted_tickets(c, true) = 2, 'RR5: self tickets counted, got ' || public.exos_rr_counted_tickets(c, true);
  ASSERT pg_temp.rr_vouchers(c) = 1, 'RR5: no extra voucher';
  RAISE NOTICE 'OK  RR5 self-referral ignored (same user, same email)';
END $$;

-- RR6. Second threshold issues a second voucher; the cap (2) stops a third.
DO $$
DECLARE c text := current_setting('test.code_a');
BEGIN
  PERFORM pg_temp.rr_buy(c, 3);
  PERFORM pg_temp.rr_buy(c, 4);
  ASSERT pg_temp.rr_vouchers(c) = 2, 'RR6: second voucher at 4';
  PERFORM pg_temp.rr_buy(c, 5);
  PERFORM pg_temp.rr_buy(c, 6);
  ASSERT public.exos_rr_counted_tickets(c, true) = 6, 'RR6: 6 counted';
  ASSERT pg_temp.rr_vouchers(c) = 2, 'RR6: cap of 2 respected, got ' || pg_temp.rr_vouchers(c);
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-0000000000a1',false);
  ASSERT public.exos_my_referral_progress('a7000000-0000-0000-0000-0000000000e1')->'nextThreshold' = 'null'::jsonb,
         'RR6: no next threshold once capped';
  RAISE NOTICE 'OK  RR6 second threshold + cap';
END $$;

-- RR7. Re-running the sync (and the rule save) is a no-op.
DO $$
DECLARE c text := current_setting('test.code_a'); before int := (SELECT count(*) FROM public.exos_vouchers);
BEGIN
  ASSERT public.exos_referral_rewards_sync(c) = 0, 'RR7: sync changed something';
  ASSERT public.exos_referral_rewards_sync(c) = 0, 'RR7: second sync changed something';
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-00000000000a',false);
  PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e1', NULL, true, 2, 2, true,
    NULL, 'a7000000-0000-0000-0000-0000000000d2', 'price', 0);
  ASSERT (SELECT count(*) FROM public.exos_vouchers) = before AND pg_temp.rr_vouchers(c) = 2, 'RR7: no new vouchers';
  RAISE NOTICE 'OK  RR7 idempotent';
END $$;

-- RR8. A redeems reward 1 (free ticket). Voids: an unused reward below its
--      threshold is revoked (and reinstated if the count comes back); a used
--      one is kept.
DO $$
DECLARE c text := current_setting('test.code_a'); r1 uuid; r2 uuid; v1 public.exos_vouchers%ROWTYPE; v2 public.exos_vouchers%ROWTYPE;
        tid uuid; p jsonb;
BEGIN
  SELECT id INTO r1 FROM public.exos_referral_rewards WHERE referral_code = c AND milestone = 1;
  SELECT id INTO r2 FROM public.exos_referral_rewards WHERE referral_code = c AND milestone = 2;
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-000000000005',false);
  BEGIN
    PERFORM public.exos_redeem_referral_reward(r1);
    RAISE EXCEPTION 'RR8: a stranger redeemed A''s reward';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-0000000000a1',false);
  tid := public.exos_redeem_referral_reward(r1);
  ASSERT (SELECT tier_id = 'a7000000-0000-0000-0000-0000000000d2' AND owner_id = 'a7000000-0000-0000-0000-0000000000a1'
            AND price_paid = 0 AND status = 'active' FROM public.exos_tickets WHERE id = tid), 'RR8: reward ticket minted';
  BEGIN
    PERFORM public.exos_redeem_referral_reward(r1);
    RAISE EXCEPTION 'RR8: redeemed twice';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- 6 -> 4: both thresholds still met.
  UPDATE public.exos_tickets SET status = 'voided' WHERE referral_code = c AND buyer_email IN ('friend5@y.com','friend6@y.com');
  ASSERT (SELECT count(*) FROM public.exos_referral_rewards WHERE referral_code = c AND status = 'issued') = 2, 'RR8: nothing revoked at 4';
  -- 4 -> 3: reward 2 (unused) revoked, its voucher expired.
  UPDATE public.exos_tickets SET status = 'refunded' WHERE referral_code = c AND buyer_email = 'friend4@y.com';
  ASSERT (SELECT status FROM public.exos_referral_rewards WHERE id = r2) = 'revoked', 'RR8: reward 2 revoked';
  SELECT v.* INTO v2 FROM public.exos_vouchers v JOIN public.exos_referral_rewards rr ON rr.voucher_id = v.id WHERE rr.id = r2;
  ASSERT (SELECT reason FROM public.exos_check_voucher(v2.event_id, v2.code, 'fana@x.com')) = 'expired', 'RR8: revoked voucher unusable';
  p := public.exos_my_referral_progress('a7000000-0000-0000-0000-0000000000e1');
  ASSERT (SELECT r->'code' FROM jsonb_array_elements(p->'rewards') r WHERE r->>'id' = r2::text) = 'null'::jsonb,
         'RR8: revoked code hidden from the fan';
  -- Back to 4: reinstated with the same code.
  PERFORM pg_temp.rr_buy(c, 7);
  ASSERT (SELECT status FROM public.exos_referral_rewards WHERE id = r2) = 'issued', 'RR8: reward 2 reinstated';
  ASSERT (SELECT is_valid FROM public.exos_check_voucher(v2.event_id, v2.code, 'fana@x.com')), 'RR8: reinstated voucher valid';
  ASSERT pg_temp.rr_vouchers(c) = 2, 'RR8: reinstating reused the voucher';
  -- Down to 1: the used reward 1 is kept, reward 2 revoked again.
  UPDATE public.exos_tickets SET status = 'voided'
   WHERE referral_code = c AND buyer_email IN ('friend2@y.com','friend3@y.com','friend7@y.com');
  ASSERT public.exos_rr_counted_tickets(c, true) = 1, 'RR8: 1 counted';
  ASSERT (SELECT status FROM public.exos_referral_rewards WHERE id = r1) = 'issued', 'RR8: used reward kept';
  SELECT * INTO v1 FROM public.exos_vouchers WHERE id = (SELECT voucher_id FROM public.exos_referral_rewards WHERE id = r1);
  ASSERT v1.used_count = 1 AND v1.valid_until IS NULL, 'RR8: used voucher untouched';
  ASSERT (SELECT status FROM public.exos_referral_rewards WHERE id = r2) = 'revoked', 'RR8: unused reward revoked';
  RAISE NOTICE 'OK  RR8 redeem; void revokes unused, keeps used; reinstates on recount';
END $$;

-- RR9. No confirmed email, no reward; confirming catches up on the next progress read.
DO $$
DECLARE c text := current_setting('test.code_u'); p jsonb;
BEGIN
  PERFORM pg_temp.rr_buy(c, 8);
  PERFORM pg_temp.rr_buy(c, 9);
  ASSERT pg_temp.rr_vouchers(c) = 0, 'RR9: unconfirmed referrer got a reward';
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-0000000000a2',false);
  p := public.exos_my_referral_progress('a7000000-0000-0000-0000-0000000000e1');
  ASSERT NOT (p->>'emailConfirmed')::boolean AND jsonb_array_length(p->'rewards') = 0, 'RR9: progress ' || p::text;
  UPDATE auth.users SET email_confirmed_at = now() WHERE id = 'a7000000-0000-0000-0000-0000000000a2';
  p := public.exos_my_referral_progress('a7000000-0000-0000-0000-0000000000e1');
  ASSERT jsonb_array_length(p->'rewards') = 1 AND pg_temp.rr_vouchers(c) = 1, 'RR9: caught up after confirming';
  RAISE NOTICE 'OK  RR9 confirmed email required';
END $$;

-- RR10. Leaderboard: staff (incl. finance) see names or masked emails only.
DO $$
DECLARE r record; n int := 0;
BEGIN
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-00000000000f',false);
  FOR r IN SELECT * FROM public.exos_referral_leaderboard('a7000000-0000-0000-0000-0000000000e1') LOOP
    n := n + 1;
    ASSERT r.label NOT LIKE '%fana@x.com%' AND r.label NOT LIKE '%fanu@x.com%', 'RR10: full email leaked: ' || r.label;
    IF r.label = 'Uma' THEN
      ASSERT r.tickets = 2 AND r.rewards_issued = 1 AND r.rank = 1, 'RR10: U row ' || row_to_json(r)::text;
    ELSE
      ASSERT r.label = 'fa***@x***.com', 'RR10: A masked, got ' || r.label;
      ASSERT r.tickets = 1 AND r.rewards_issued = 1 AND r.rewards_redeemed = 1, 'RR10: A row ' || row_to_json(r)::text;
    END IF;
  END LOOP;
  ASSERT n = 2, 'RR10: two referrers, got ' || n;
  ASSERT public.exos_rr_mask_email('ab@c.io') = 'a***@c***.io', 'RR10: short mask';
  RAISE NOTICE 'OK  RR10 leaderboard masks emails';
END $$;

-- RR11. Org default applies to events without a rule; % off becomes a pinned
--       price; paid-only counting; a discount can't be "redeemed" for free;
--       disabling stops new rewards; deleting the fan's code closes the voucher.
DO $$
DECLARE c text := current_setting('test.code_a3'); v public.exos_vouchers%ROWTYPE; rid uuid;
BEGIN
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-00000000000a',false);
  PERFORM public.exos_set_referral_reward_rule(NULL, 'a7000000-0000-0000-0000-000000000001', true, 1, 3, false,
    'a7000000-0000-0000-0000-0000000000e2', 'a7000000-0000-0000-0000-0000000000d3', 'percent_off', 25);
  ASSERT (public.exos_get_referral_reward_rule('a7000000-0000-0000-0000-0000000000e2')->>'applies') = 'org', 'RR11: default applies';
  PERFORM pg_temp.rr_buy(c, 1, 0, 'e2');           -- free claim: not counted (paid only)
  ASSERT pg_temp.rr_vouchers(c) = 0, 'RR11: free ticket counted under paid-only';
  PERFORM pg_temp.rr_buy(c, 2, 40, 'e2');
  ASSERT pg_temp.rr_vouchers(c) = 1, 'RR11: paid ticket earns';
  SELECT v2.* INTO v FROM public.exos_vouchers v2 JOIN public.exos_referral_rewards rr ON rr.voucher_id = v2.id WHERE rr.referral_code = c;
  ASSERT v.price_override = 30 AND v.tier_id = 'a7000000-0000-0000-0000-0000000000d3', 'RR11: 25% off $40 = $30, got ' || v.price_override;
  SELECT id INTO rid FROM public.exos_referral_rewards WHERE referral_code = c;
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-0000000000a3',false);
  BEGIN
    PERFORM public.exos_redeem_referral_reward(rid);
    RAISE EXCEPTION 'RR11: discount redeemed as free';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-00000000000a',false);
  PERFORM public.exos_set_referral_reward_rule(NULL, 'a7000000-0000-0000-0000-000000000001', false, 1, 3, false,
    'a7000000-0000-0000-0000-0000000000e2', 'a7000000-0000-0000-0000-0000000000d3', 'percent_off', 25);
  PERFORM pg_temp.rr_buy(c, 3, 40, 'e2');
  ASSERT pg_temp.rr_vouchers(c) = 1, 'RR11: disabled rule still issued';
  DELETE FROM public.exos_fan_referrals WHERE code = c;   -- what account deletion does
  SELECT * INTO v FROM public.exos_vouchers WHERE id = v.id;
  ASSERT v.reserved_email IS NULL AND v.valid_until <= now(), 'RR11: orphaned voucher closed';
  RAISE NOTICE 'OK  RR11 org default, %% off, paid-only, disable, deletion';
END $$;

-- RR12. The E1 rule's own tickets didn't count the reward ticket as a referral.
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_tickets WHERE channel_source = 'referral_reward' AND referral_code IS NOT NULL),
         'RR12: reward tickets carry no referral code';
  RAISE NOTICE 'OK  RR12 reward tickets are not referrals';
END $$;

-- RR13. A free reward on "any ticket type": redeeming without a pick uses
--       the first public tier; a hidden tier can't be picked.
DO $$
DECLARE c text; rid uuid; tid uuid;
BEGIN
  INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,visibility) VALUES
    ('a7000000-0000-0000-0000-0000000000d4','a7000000-0000-0000-0000-0000000000e0','Secret',50,0,'hidden');
  INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,buyer_email,status,price_paid,order_ref,barcode_secret) VALUES
    ('a7000000-0000-0000-0000-0000000000e0','a7000000-0000-0000-0000-000000000001','a7000000-0000-0000-0000-0000000000d0',
     'a7000000-0000-0000-0000-0000000000a1','a7000000-0000-0000-0000-0000000000a1','fana@x.com','active',20,'rr-a-e0','s');
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-00000000000a',false);
  PERFORM public.exos_set_referral_reward_rule('a7000000-0000-0000-0000-0000000000e0', NULL, true, 1, 1, true, NULL, NULL, 'price', 0);
  PERFORM set_config('app.uid','a7000000-0000-0000-0000-0000000000a1',false);
  c := public.exos_my_referral_code('a7000000-0000-0000-0000-0000000000e0');
  PERFORM pg_temp.rr_buy(c, 1, 20, 'e0');
  SELECT id INTO rid FROM public.exos_referral_rewards WHERE referral_code = c;
  ASSERT rid IS NOT NULL AND (SELECT tier_id FROM public.exos_vouchers v JOIN public.exos_referral_rewards rr ON rr.voucher_id = v.id
                               WHERE rr.id = rid) IS NULL, 'RR13: any-tier voucher';
  BEGIN
    PERFORM public.exos_redeem_referral_reward(rid, 'a7000000-0000-0000-0000-0000000000d4');
    RAISE EXCEPTION 'RR13: hidden tier picked';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  tid := public.exos_redeem_referral_reward(rid);
  ASSERT (SELECT tier_id FROM public.exos_tickets WHERE id = tid) = 'a7000000-0000-0000-0000-0000000000d0', 'RR13: first public tier';
  RAISE NOTICE 'OK  RR13 any-tier free reward';
END $$;

SELECT set_config('app.uid','',false);
ROLLBACK;
