-- 20260508130000_sync_check_helper_rpc.sql
-- Code-owned (auditor tooling).
--
-- One-time setup for bin/sync-check.sh: a service-role-only RPC that returns
-- the prod migration list. PostgREST exposes the public schema; this wrapper
-- gives us a read-handle on supabase_migrations.schema_migrations from
-- outside the DB without needing a Supabase PAT for the migration-diff
-- portion of the audit.
--
-- Execution restricted to service_role so anon/authenticated can't probe
-- migration history.

CREATE OR REPLACE FUNCTION public.__sync_check_list_migrations()
RETURNS TABLE (version text, name text)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT version, name
  FROM supabase_migrations.schema_migrations
  ORDER BY version;
$$;

REVOKE ALL ON FUNCTION public.__sync_check_list_migrations FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.__sync_check_list_migrations TO service_role;

COMMENT ON FUNCTION public.__sync_check_list_migrations IS
  'Sync-check helper. Service-role only. Powers bin/sync-check.sh drift detection without needing a Supabase PAT for the migration diff portion.';
