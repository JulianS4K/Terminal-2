-- ============================================================================
-- Presale set-up from the organizer UI (mig 20260925012000): a chosen code,
-- restricted to a hidden tier, matched case-insensitively. Runs after
-- test_trial_run_fixes_2.sql; reuses the f1 org (owner f1…0b) and the hidden
-- Presale tier f5.
-- ============================================================================
\set ON_ERROR_STOP on

DO $$
DECLARE v_code text; r record;
BEGIN
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-00000000000b',false);
  v_code := public.exos_issue_voucher('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-0000000000f5',
                                      NULL, false, NULL, 30, NULL, 'presale', 'presale-night');
  ASSERT v_code = 'PRESALE-NIGHT', 'P1: chosen code stored upper-case, got '||v_code;
  SELECT * INTO r FROM public.exos_check_voucher('f1000000-0000-0000-0000-0000000000e1', 'Presale-Night ');
  ASSERT r.is_valid AND r.restrict_tier_id = 'f1000000-0000-0000-0000-0000000000f5', 'P1: any case matches, tier kept';
  ASSERT (SELECT max_uses FROM public.exos_vouchers WHERE code='PRESALE-NIGHT') = 30, 'P1: uses kept';
  BEGIN
    PERFORM public.exos_issue_voucher('f1000000-0000-0000-0000-0000000000e1', NULL, NULL, true, NULL, 1, NULL, NULL, 'PRESALE-night');
    RAISE EXCEPTION 'P1: duplicate code accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_issue_voucher('f1000000-0000-0000-0000-0000000000e1', NULL, NULL, true, NULL, 1, NULL, NULL, 'no spaces!');
    RAISE EXCEPTION 'P1: bad code accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_issue_voucher('f1000000-0000-0000-0000-0000000000e1', 'f0000000-0000-0000-0000-0000000000d2');
    RAISE EXCEPTION 'P1: tier from another event accepted';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%not on this event%', 'P1: clear message';
  END;
  ASSERT public.exos_issue_voucher('f1000000-0000-0000-0000-0000000000e1') ~ '^[0-9A-F]{12}$', 'P1: random code still minted';
  RAISE NOTICE 'OK  P1 presale voucher with a chosen code, any case';
END $$;
