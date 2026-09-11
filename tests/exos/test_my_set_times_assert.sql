-- Assertions for migration 20260713150000, run AFTER seed + migration apply.
DO $$
DECLARE has_col boolean; dflt text; raised boolean := false; n int; st jsonb;
BEGIN
  -- 1. Column exists with a jsonb '[]' default.
  SELECT true, column_default INTO has_col, dflt
    FROM information_schema.columns
   WHERE table_name='exos_events' AND column_name='set_times';
  ASSERT has_col, 'set_times column must exist';
  ASSERT dflt LIKE '%[]%', 'set_times default must be []';

  -- 2. Array-only CHECK rejects a non-array.
  BEGIN
    INSERT INTO public.exos_events (id, set_times) VALUES (gen_random_uuid(), '{"a":1}'::jsonb);
  EXCEPTION WHEN check_violation THEN raised := true;
  END;
  ASSERT raised, 'set_times CHECK must reject a non-array value';

  -- 3. Round-trip a real schedule; the public view exposes it.
  INSERT INTO public.exos_events (id, name, status, set_times)
    VALUES ('dddddddd-0000-0000-0000-000000000001','Set Times Show','published',
            '[{"label":"Opener","at":"2026-08-01T20:00:00.000Z"},{"label":"Headliner","at":"2026-08-01T21:30:00.000Z"}]'::jsonb);
  SELECT set_times INTO st FROM public.exos_public_events WHERE id='dddddddd-0000-0000-0000-000000000001';
  ASSERT jsonb_array_length(st) = 2, 'public view must expose the 2 set times';
  ASSERT st->0->>'label' = 'Opener', 'first set time label must round-trip';

  RAISE NOTICE 'set_times column/check/view/round-trip ok';
END $$;

-- 4. anon can read set_times off the base table (column grant added by migration).
SET ROLE anon;
SELECT set_times FROM public.exos_events WHERE id='dddddddd-0000-0000-0000-000000000001';
RESET ROLE;

SELECT '*** MY SET-TIMES MIGRATION TEST PASSED ***' AS result;
