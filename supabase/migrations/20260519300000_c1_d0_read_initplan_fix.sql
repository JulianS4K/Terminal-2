-- 20260519300000_c1_d0_read_initplan_fix.sql
--
-- Cluster 2 from C1's Supabase Action Center brief 2026-05-18.
-- Clears 10 `auth_rls_initplan` advisor WARNs.
--
-- Current USING clause:
--   (COALESCE((auth.jwt() ->> 'email'::text), ''::text) ~~ '%@s4kent.com'::text)
-- Postgres re-evaluates auth.jwt() per row, which the advisor flags.
--
-- Fix: wrap auth.jwt() in a sub-SELECT. PG executes the sub-SELECT once
-- and caches as an InitPlan node — same semantics, ~per-row evaluation cost
-- collapses to one evaluation per query.
--
-- Verified 2026-05-18 against prod: the policy `d0_s4kent_read` exists on
-- all 10 tables with identical USING clause shape (no per-table semantic drift).

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'events','event_xref','sg_events_canonical','aq_event_map','aq_venue_map',
    'aq_performer_map','performer_metadata','venue_assets','cron_policy','cron_gate_decisions'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP POLICY IF EXISTS d0_s4kent_read ON public.%I', t);
    EXECUTE format($f$
      CREATE POLICY d0_s4kent_read ON public.%I
        FOR SELECT TO authenticated
        USING (coalesce((select auth.jwt()->>'email'), '') LIKE '%%@s4kent.com')
    $f$, t);
  END LOOP;
END $$;

-- ============================================================
-- Post-apply verification
-- ============================================================
-- 1) All 10 policies show the (select auth.jwt()...) form:
-- SELECT tablename, qual FROM pg_policies
-- WHERE schemaname='public' AND policyname='d0_s4kent_read' ORDER BY tablename;
--
-- 2) EXPLAIN (ANALYZE, VERBOSE) a representative authenticated query —
--    InitPlan node should appear ONCE rather than per-row Filter:
-- EXPLAIN (ANALYZE) SELECT 1 FROM public.events LIMIT 1;
--    Look for "InitPlan 1 (returns $0)" referencing auth.jwt() rather than
--    "Filter: (... auth.jwt() ...)" applied per row.
--
-- 3) Re-run get_advisors(performance): 10 `auth_rls_initplan` WARNs should clear.
