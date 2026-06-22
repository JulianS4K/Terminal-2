-- ============================================================================
-- Migration 20260622200000 — RLS initplan optimization (wrap auth.* in subselect)
--
-- Lane:     A1 (DB-layer security/perf — RLS)
-- Touches:  11 SELECT/INSERT/UPDATE/ALL policies on event_watchlist, exos_*,
--           seatmap_manifest, user_alerts (DROP + CREATE with identical logic)
-- Pre-reqs: none
--
-- WHY (2026-06-22 audit / performance advisor `auth_rls_initplan`):
--   A bare auth.uid()/auth.jwt() in a policy is re-evaluated PER ROW. Wrapping
--   the row-independent call as (select auth.uid()) lets Postgres hoist it to a
--   one-time InitPlan — same result, big win on large scans. This is the exact
--   Supabase-recommended rewrite; it is SEMANTICS-PRESERVING (the value does not
--   depend on the row, so caching it changes nothing).
--
--   Row-DEPENDENT calls are intentionally left as-is: exos_has_org_role(org_id,…)
--   / exos_is_admin() take per-row columns (org_id) so they cannot be hoisted to
--   a scalar subselect. Only the constant auth.uid()/auth.jwt() are wrapped.
--
--   Each policy below is DROP + CREATE with byte-identical predicate logic apart
--   from the (select …) wrap. cmd / permissive / role / qual / with_check are
--   preserved exactly (verified against pg_policies 2026-06-22).
-- ============================================================================

-- event_watchlist
DROP POLICY IF EXISTS event_watchlist_owner_sel ON public.event_watchlist;
CREATE POLICY event_watchlist_owner_sel ON public.event_watchlist
  FOR SELECT TO authenticated
  USING ((user_email = lower(((select auth.jwt()) ->> 'email'))) AND (((select auth.jwt()) ->> 'email') ~~ '%@s4kent.com'));

-- exos_org_follows
DROP POLICY IF EXISTS exos_org_follows_sel ON public.exos_org_follows;
CREATE POLICY exos_org_follows_sel ON public.exos_org_follows
  FOR SELECT TO authenticated
  USING (follower_uid = (select auth.uid()));

-- exos_org_invites
DROP POLICY IF EXISTS exos_invites_sel ON public.exos_org_invites;
CREATE POLICY exos_invites_sel ON public.exos_org_invites
  FOR SELECT TO authenticated
  USING ((lower(email) = lower(COALESCE(((select auth.jwt()) ->> 'email'), ''))) OR exos_has_org_role(org_id, ARRAY['owner']));

-- exos_org_memberships
DROP POLICY IF EXISTS exos_memberships_sel ON public.exos_org_memberships;
CREATE POLICY exos_memberships_sel ON public.exos_org_memberships
  FOR SELECT TO authenticated
  USING ((user_id = (select auth.uid())) OR exos_has_org_role(org_id, ARRAY['owner','manager']));

-- exos_profiles (INSERT + UPDATE)
DROP POLICY IF EXISTS exos_profiles_ins ON public.exos_profiles;
CREATE POLICY exos_profiles_ins ON public.exos_profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = (select auth.uid()));

DROP POLICY IF EXISTS exos_profiles_upd ON public.exos_profiles;
CREATE POLICY exos_profiles_upd ON public.exos_profiles
  FOR UPDATE TO authenticated
  USING (id = (select auth.uid()))
  WITH CHECK (id = (select auth.uid()));

-- exos_scan_rejects
DROP POLICY IF EXISTS exos_scan_rejects_ins ON public.exos_scan_rejects;
CREATE POLICY exos_scan_rejects_ins ON public.exos_scan_rejects
  FOR INSERT TO authenticated
  WITH CHECK ((rejected_by = (select auth.uid())) AND (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','scanner'])));

-- exos_tickets
DROP POLICY IF EXISTS exos_tickets_sel ON public.exos_tickets;
CREATE POLICY exos_tickets_sel ON public.exos_tickets
  FOR SELECT TO authenticated
  USING ((owner_id = (select auth.uid())) OR (buyer_id = (select auth.uid())) OR exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));

-- exos_transfers
DROP POLICY IF EXISTS exos_transfers_sel ON public.exos_transfers;
CREATE POLICY exos_transfers_sel ON public.exos_transfers
  FOR SELECT TO authenticated
  USING ((sender_id = (select auth.uid())) OR (lower(receiver_email) = lower(COALESCE(((select auth.jwt()) ->> 'email'), ''))) OR exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

-- seatmap_manifest
DROP POLICY IF EXISTS seatmap_manifest_s4kent_read ON public.seatmap_manifest;
CREATE POLICY seatmap_manifest_s4kent_read ON public.seatmap_manifest
  FOR SELECT TO authenticated
  USING (((select auth.jwt()) ->> 'email') ~~ '%@s4kent.com');

-- user_alerts
DROP POLICY IF EXISTS user_alerts_owner_all ON public.user_alerts;
CREATE POLICY user_alerts_owner_all ON public.user_alerts
  FOR ALL TO authenticated
  USING (owner_id = (select auth.uid()))
  WITH CHECK (owner_id = (select auth.uid()));
