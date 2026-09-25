-- ============================================================================
-- Re-running the fulfillment migrations is harmless (review 2026-09-25).
-- run_p0.sh re-applies 215000, 223000 and 234500 before this file; the live
-- exos_fulfill_checkout must still be the all-or-nothing body carrying both
-- promoter and referral credit (a replay of 215000 used to strip them).
-- ============================================================================
\set ON_ERROR_STOP on
DO $$
DECLARE d text := pg_get_functiondef('public.exos_fulfill_checkout(text)'::regprocedure);
BEGIN
  ASSERT position('XF001' in d) > 0, 'replay: all-or-nothing body kept';
  ASSERT position('s.promoter_id' in d) > 0, 'replay: promoter credit kept';
  ASSERT position('referral_code' in d) > 0, 'replay: referral credit kept';
  ASSERT (length(d) - length(replace(d, 'referral_code', ''))) / length('referral_code') = 1, 'replay: patched exactly once';
  RAISE NOTICE 'OK  replaying the fulfillment migrations is a no-op';
END $$;
