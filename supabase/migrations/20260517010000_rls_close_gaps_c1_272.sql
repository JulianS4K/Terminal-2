-- ============================================================================
-- Closes C1 #272 (5 RLS gaps).
--
-- NEW from PR #177 (A1 sg-bridge):
--   • cross_source_venue_map
--   • sg_tevo_search_attempts
-- Carryover (pre-existing):
--   • sg_event_priority_state
--   • sg_priority_policy
--   • cron_pause_state_20260514
--
-- All 5 had rls_enabled=false + policy_count=0 (confirmed via pg_class +
-- pg_policy probe). Pattern follows 20260515300000 (aq_venue_map /
-- aq_performer_map close-out by B1):
--   • ENABLE ROW LEVEL SECURITY
--   • admin_only deny-all policy (anon, authenticated, coworker_readonly)
--   • REVOKE ALL FROM anon, authenticated (belt + suspenders alongside RLS)
--   • GRANT service_role for SECDEF callers
--
-- Post-apply verified: all 5 → rls_enabled=true + policy_count=1.
--
-- pr_governance §"Pre-merge gate" suggestion (C1 #272): consider hard-fail
-- on advisor-ERROR class as PR check. Deferred to follow-up.
-- ============================================================================

ALTER TABLE public.cross_source_venue_map     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sg_tevo_search_attempts    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sg_event_priority_state    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sg_priority_policy         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cron_pause_state_20260514  ENABLE ROW LEVEL SECURITY;

-- Deny-all policies (idempotent via DO blocks — CREATE POLICY has no IF NOT EXISTS).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='cross_source_venue_map' AND policyname='admin_only') THEN
    CREATE POLICY admin_only ON public.cross_source_venue_map FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='sg_tevo_search_attempts' AND policyname='admin_only') THEN
    CREATE POLICY admin_only ON public.sg_tevo_search_attempts FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='sg_event_priority_state' AND policyname='admin_only') THEN
    CREATE POLICY admin_only ON public.sg_event_priority_state FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='sg_priority_policy' AND policyname='admin_only') THEN
    CREATE POLICY admin_only ON public.sg_priority_policy FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='cron_pause_state_20260514' AND policyname='admin_only') THEN
    CREATE POLICY admin_only ON public.cron_pause_state_20260514 FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);
  END IF;
END $$;

REVOKE ALL ON public.cross_source_venue_map     FROM anon, authenticated;
REVOKE ALL ON public.sg_tevo_search_attempts    FROM anon, authenticated;
REVOKE ALL ON public.sg_event_priority_state    FROM anon, authenticated;
REVOKE ALL ON public.sg_priority_policy         FROM anon, authenticated;
REVOKE ALL ON public.cron_pause_state_20260514  FROM anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.cross_source_venue_map     TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sg_tevo_search_attempts    TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sg_event_priority_state    TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sg_priority_policy         TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cron_pause_state_20260514  TO service_role;
