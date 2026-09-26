-- ============================================================================
-- A voucher reveals the hidden tier it unlocks (mig 20260925000000). Runs
-- after test_fan_referrals.sql in the same DB; reuses the f1 fixtures.
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('f1000000-0000-0000-0000-0000000000f5','f1000000-0000-0000-0000-0000000000e1','Presale (hidden)',15,20,0,'hidden');
INSERT INTO public.exos_vouchers(event_id,code,tier_id,max_uses) VALUES
  ('f1000000-0000-0000-0000-0000000000e1','F1PRESALE','f1000000-0000-0000-0000-0000000000f5',5),
  ('f1000000-0000-0000-0000-0000000000e1','F1ANYTIER',NULL,5);

SET ROLE anon;
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM public.exos_voucher_tier('f1000000-0000-0000-0000-0000000000e1','F1PRESALE');
  ASSERT r.id = 'f1000000-0000-0000-0000-0000000000f5' AND r.name = 'Presale (hidden)' AND r.price = 15,
         'V1: valid code reveals its hidden tier';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_voucher_tier('f1000000-0000-0000-0000-0000000000e1','WRONG')), 'V1: bad code reveals nothing';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_voucher_tier('f1000000-0000-0000-0000-0000000000e1','F1ANYTIER')), 'V1: unrestricted code has no tier';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_voucher_tier('f1000000-0000-0000-0000-0000000000e2','F1PRESALE')), 'V1: code scoped to its event';
  RAISE NOTICE 'OK  V1 voucher reveals only its own hidden tier';
END $$;
RESET ROLE;

-- V2. A used-up code no longer reveals the tier.
UPDATE public.exos_vouchers SET used_count = max_uses WHERE code = 'F1PRESALE';
SET ROLE anon;
DO $$
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_voucher_tier('f1000000-0000-0000-0000-0000000000e1','F1PRESALE')), 'V2: spent code reveals nothing';
  RAISE NOTICE 'OK  V2 spent voucher hides the tier again';
END $$;
RESET ROLE;
