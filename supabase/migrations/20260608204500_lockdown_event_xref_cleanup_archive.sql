-- ============================================================================
-- MIG 20260608204500 — lock down stray cleanup-archive table (B1-NEXT-60)
--
-- `event_xref_cleanup_archive_20260606` (a dated 2026-06-06 event_xref cleanup
-- archive, 155 rows) carried a blanket `..._authenticated_select` policy
-- (`USING(true)`) → any authenticated user could read it. No frontend/app/edge
-- code reads it and no view depends on it; the data is non-sensitive event_xref
-- rows, but a stray archive table should not be authenticated-readable.
--
-- Drop the permissive policy + add the standard `admin_only` deny (RLS already
-- on). service_role / SECDEF readers are unaffected (BYPASSRLS).
--
-- (`leads` carries a DELIBERATE `leads_authenticated_read USING(true)` policy —
--  left untouched here; flagged on the B1-NEXT-60 row for owner review to tighten
--  to an admin claim, since it appears to back an intended authenticated reader
--  and the rows are likely PII.)
--
-- ✅ Already applied to prod  Applied via MCP 2026-06-08.
--    Post-apply verified: authenticated SELECT on the archive table = false.
-- ============================================================================

DROP POLICY IF EXISTS event_xref_cleanup_archive_20260606_authenticated_select
  ON public.event_xref_cleanup_archive_20260606;
DROP POLICY IF EXISTS admin_only ON public.event_xref_cleanup_archive_20260606;
CREATE POLICY admin_only ON public.event_xref_cleanup_archive_20260606
  FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);
