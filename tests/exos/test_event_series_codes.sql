-- ============================================================================
-- Creating a series copies the template's discount codes (mig 20260925001000).
-- The stub schema has no exos_discount_codes, so this adds one with prod's
-- columns. Runs after test_exos_platform.sql; reuses its 99999999 template.
-- ============================================================================
\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS public.exos_discount_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.exos_events(id) ON DELETE CASCADE,
  code text NOT NULL, type text NOT NULL CHECK (type IN ('percentage','fixed')),
  value numeric NOT NULL, usage_limit int, used_count int NOT NULL DEFAULT 0,
  expires_at timestamptz, unlocks_tier_ids uuid[],
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.exos_discount_codes(event_id,code,type,value,usage_limit,used_count)
VALUES ('99999999-0000-0000-0000-0000000000e1','SERIES10','percentage',10,50,7);

SELECT set_config('app.uid','11111111-1111-1111-1111-111111111111',false);
DO $$
DECLARE v_new uuid;
BEGIN
  SELECT event_id INTO v_new FROM public.exos_create_event_series('99999999-0000-0000-0000-0000000000e1',
    ARRAY['2027-02-05 20:00-05']::timestamptz[], 'recurring', NULL, NULL, false);
  ASSERT (SELECT count(*) FROM public.exos_discount_codes WHERE event_id = v_new AND code = 'SERIES10'
            AND type = 'percentage' AND value = 10 AND usage_limit = 50 AND used_count = 0) = 1,
         'S1: code copied to the new occurrence with its usage reset';
  ASSERT (SELECT used_count FROM public.exos_discount_codes
           WHERE event_id = '99999999-0000-0000-0000-0000000000e1' AND code = 'SERIES10') = 7,
         'S1: template code unchanged';
  RAISE NOTICE 'OK  S1 series copies discount codes';
END $$;
