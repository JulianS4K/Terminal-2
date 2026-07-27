-- Migration 20260514181000 · level:admin · lane:Audit/Push · writes:215 public functions (search_path GUC) · reads:- · pre:20260514180000
-- Security advisor WARN sweep — Level 2a of the post-pause cleanup.
--
-- Before: 215 WARN function_search_path_mutable lints. Functions without
--         a fixed search_path are vulnerable to search-path injection if
--         a malicious schema or hostile object shadows a public name.
-- After:  0 WARN of this class. Verified post-apply (347 → 132 total advisor lints).
-- Cumulative since Level 1: 486 → 132 (−73%).
--
-- Scope: every function in public schema that
--   - has prokind = 'f' (true function, not aggregate/window/procedure)
--   - has no existing search_path setting in proconfig
--   - is NOT owned by an extension (those go via the extension-move fix)
-- Count: 215 (matches advisor exactly after filtering 35 extension-owned).
--
-- Each function gets SET search_path = public, pg_temp (the canonical safe
-- value used in all PR #67/#68 SECURITY DEFINER fns). Idempotent.
-- Reversible: ALTER FUNCTION <name>(<args>) RESET search_path.
--
-- Operator directive: kanban + level-by-level. This is Level 2a (largest WARN bucket).
--
-- Already applied to prod via MCP at 2026-05-14 ~17:40 UTC during the
-- cron-paused window (bot_chat row 106). This PR is the idempotent
-- codification per SYNC_PROTOCOL §5. Re-apply is a no-op (functions that
-- already have search_path set are skipped by the WHERE filter).

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT format('ALTER FUNCTION %I.%I(%s) SET search_path = public, pg_temp',
                  n.nspname, p.proname,
                  pg_get_function_identity_arguments(p.oid)) AS cmd
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig,'{}'::text[])) AS c WHERE c LIKE 'search_path=%')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE r.cmd;
  END LOOP;
END $$;
