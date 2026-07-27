-- ============================================================================
-- 20260511000100 — security: SET search_path on SECURITY DEFINER functions
--
-- Three public RPCs created in 20260508140000 are SECURITY DEFINER but did
-- not set search_path. Per Postgres docs this is the canonical privilege-
-- escalation vector — a caller can prepend a malicious schema and intercept
-- any unqualified reference inside the function.
--
-- This migration adds `SET search_path = public, pg_temp` to each. The
-- pg_temp is appended last so a temp object can never shadow a public one.
--
-- Run-anywhere safe: ALTER FUNCTION is idempotent on `SET search_path`.
--
-- Filed by: A1 · 2026-05-11 security chat · SEC-HIGH entry in KANBAN.md.
-- ============================================================================

ALTER FUNCTION public.get_event_assets_public(bigint)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.get_performer_assets_public(bigint)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.get_venue_assets_public(bigint)
  SET search_path = public, pg_temp;

-- Also sweep any other SECURITY DEFINER function in public.* that's still
-- missing search_path. Safe-no-op if there are none.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname || '.' || p.proname || '(' ||
           pg_get_function_identity_arguments(p.oid) || ')' AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) AS c
        WHERE c LIKE 'search_path=%'
      )
  LOOP
    EXECUTE 'ALTER FUNCTION ' || r.sig || ' SET search_path = public, pg_temp';
    RAISE NOTICE 'security: set search_path on %', r.sig;
  END LOOP;
END $$;
