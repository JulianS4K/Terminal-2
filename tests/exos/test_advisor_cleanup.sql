-- 20260926000000: client roles can't execute trigger bodies or the quota stock
-- helper; triggers and the definer paths that use it still work.
\set ON_ERROR_STOP on
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname LIKE 'exos\_tg\_%' AND p.prorettype = 'trigger'::regtype
     AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  ASSERT n = 0, 'A1: a trigger function is still client-executable';
  IF to_regprocedure('public.exos_quota_available(uuid)') IS NOT NULL THEN
    ASSERT NOT has_function_privilege('anon', 'public.exos_quota_available(uuid)', 'EXECUTE'), 'A2: anon quota';
    ASSERT NOT has_function_privilege('authenticated', 'public.exos_quota_available(uuid)', 'EXECUTE'), 'A2: auth quota';
    ASSERT has_function_privilege('service_role', 'public.exos_quota_available(uuid)', 'EXECUTE'), 'A2: service quota';
  END IF;
  IF to_regprocedure('public.exos_tax_cents(integer, numeric, boolean)') IS NOT NULL THEN
    ASSERT (SELECT proconfig::text FROM pg_proc WHERE oid = 'public.exos_tax_cents(integer, numeric, boolean)'::regprocedure)
           LIKE '%search_path%', 'A3: tax_cents search_path';
  END IF;
  RAISE NOTICE 'OK  A1-A3 advisor clean-up';
END $$;
