-- ============================================================
-- SECURITY P2 — supporting hardening (2026-06-01).
-- Source: Supabase Security Advisor lints 0016 (materialized_view_in_api) and
-- 0011 (function_search_path_mutable).
--
-- (A) Materialized views selectable by anon/authenticated. MVs cannot carry RLS, so the
-- only control is the grant. Both are internal dashboards/metrics; revoke client read.
-- Backend reads via service_role and is unaffected.
REVOKE SELECT ON public.v_dashboard_writes_24h FROM anon, authenticated;
REVOKE SELECT ON public.latest_event_metrics   FROM anon, authenticated;

-- (B) Pin mutable search_path on the one flagged function (injection-surface hardening).
-- The 12 SECDEF jobs in the P1 migration already pin search_path; this one was missed.
ALTER FUNCTION public.compute_event_breakdowns(p_event_id bigint, p_captured_at timestamp with time zone)
  SET search_path = public, pg_temp;

-- ============================================================
-- NOT auto-fixed in SQL (require operator action / out of migration scope) —
-- tracked here so the advisor delta is fully explained:
--   * Auth: leaked-password protection DISABLED — enable HaveIBeenPwned check in the
--     Auth dashboard (Auth > Policies) or via the Management API. Not a DB migration.
--   * Storage bucket `exos-media` — broad SELECT policy `exos_media_read` on storage.objects
--     allows clients to LIST all files. Public buckets don't need list for object-URL access.
--     Tightening a storage policy can break media access; left for owner review.
--   * Extensions pg_trgm / unaccent installed in `public` — moving schemas can break
--     dependent objects (indexes, functions); requires a coordinated migration. Deferred.
-- ============================================================
