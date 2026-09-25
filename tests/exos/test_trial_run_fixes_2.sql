-- ============================================================================
-- Second round of trial fixes (mig 20260925010000), the parts the stub schema
-- has. Runs after test_trial_run_fixes.sql; reuses the f1 org and event e1.
-- The full set (transfer mail, test-window scans, private profiles) is also
-- run against a copy of prod's real schema before applying.
-- ============================================================================
\set ON_ERROR_STOP on

-- U1. Referral credit: free claims only, never a paid order after the fact.
DO $$
DECLARE v_code text;
BEGIN
  INSERT INTO public.exos_fan_referrals(code,event_id,user_id)
  VALUES ('u1refcode1','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-00000000000b')
  ON CONFLICT DO NOTHING;
  SELECT code INTO v_code FROM public.exos_fan_referrals
   WHERE event_id='f1000000-0000-0000-0000-0000000000e1' AND user_id='f1000000-0000-0000-0000-00000000000b';
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status)
  VALUES ('f1-u1','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000da',
          'f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-0000000000cc','f1stranger@x.com',1,2500,'pending');
  PERFORM public.exos_fulfill_checkout('f1-u1');
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-0000000000cc',false);
  ASSERT public.exos_attach_referral('f1-u1', v_code) = 0, 'U1: paid order not credited after the fact';
  INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,price_paid,order_ref,barcode_secret)
  VALUES ('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-0000000000db',
          'f1000000-0000-0000-0000-0000000000cc','f1000000-0000-0000-0000-0000000000cc','active',0,'f1-u1-free','s');
  ASSERT public.exos_attach_referral('f1-u1-free', v_code) = 1, 'U1: free claim credited';
  RAISE NOTICE 'OK  U1 referral attach is free claims only';
END $$;

-- U2. A paid order that fails at fulfillment mails the buyer.
DO $$
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = capacity WHERE id='f1000000-0000-0000-0000-0000000000da';
  INSERT INTO public.exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status)
  VALUES ('f1-u2','f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000da',
          'f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-0000000000cc','f1Late@x.com',1,2500,'pending');
  ASSERT public.exos_fulfill_checkout('f1-u2') = '{}'::uuid[], 'U2: sold out';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template='order-failed' AND to_email='f1late@x.com') = 1,
         'U2: order-failed mail queued';
  RAISE NOTICE 'OK  U2 failed order mails the buyer';
END $$;

-- U3. Promoter handles are cleaned, shown only while tagging is allowed.
DO $$
DECLARE v_tok uuid; c jsonb;
BEGIN
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-00000000000b',false);
  PERFORM public.exos_upsert_promoter('f1000000-0000-0000-0000-000000000001','u3-dj','U3 DJ',NULL,
          '{"instagram":"@u3.dj","x":"https://x.com/u3dj"}',NULL);
  SELECT kit_token INTO v_tok FROM public.exos_promoters WHERE code='u3-dj';
  c := public.exos_public_promoter((SELECT slug FROM public.exos_orgs WHERE id='f1000000-0000-0000-0000-000000000001'), 'u3-dj');
  ASSERT c #>> '{promoter,socials,instagram}' = 'u3.dj' AND c #>> '{promoter,socials,x}' = 'u3dj', 'U3: handles cleaned';
  PERFORM public.exos_promoter_set_socials(v_tok, '{"instagram":"u3.dj"}', false);
  c := public.exos_public_promoter((SELECT slug FROM public.exos_orgs WHERE id='f1000000-0000-0000-0000-000000000001'), 'u3-dj');
  ASSERT c #> '{promoter,socials}' = '{}'::jsonb, 'U3: hidden once tagging is off';
  ASSERT (public.exos_promoter_kit(v_tok) #>> '{promoter,allow_tagging}')::boolean = false, 'U3: kit shows the switch';
  RAISE NOTICE 'OK  U3 promoter handles and tagging consent';
END $$;
