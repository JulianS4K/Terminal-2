-- Migration 20260515320000 · level:admin · lane:Audit/Push · writes:RLS policy + GRANT on 10 tables for D0 read access · pre:20260515310000
--
-- D0 SQL data access for visualization (operator directive 2026-05-15).
--
-- ARCHITECTURE: hybrid Tier-1 (RLS-gated PostgREST direct reads) +
--               Tier-3 (SECDEF RPCs, per-page assembly).
--
-- This migration ships Tier-1 ONLY. Tier-3 is per-page (get_broker_event_page
-- already shipped in 20260515310000). Tier-2 (aggregated views over heavy
-- tables) is deferred to per-surface SECDEF wrappers as demand emerges —
-- exposing the underlying matviews/heavy tables to authenticated would
-- mean granting SELECT on those tables, which we explicitly do not want.
--
-- AUTH GATE: auth.jwt()->>'email' LIKE '%@s4kent.com'
-- (consistent with get_broker_event_page email gate)
--
-- D0 frontend flow: Supabase JS client + magic-link to @s4kent.com email
-- → authenticated JWT → supabase.from('events').select(...) → RLS gates
-- by JWT email. anon role gets nothing (no GRANT).
--
-- service_role key (used by FastAPI app.py + D2 dashboard) BYPASSES RLS
-- by Supabase convention — no impact to existing backend reads. Confirmed:
-- adding RLS to a previously-no-RLS table breaks NO service_role queries.
--
-- ============================================================
-- TIER 1 WHITELIST (10 tables) — low-cardinality reference + observability
-- ============================================================
--   Canonical event data:  events, event_xref, sg_events_canonical
--   AQ canonical maps:     aq_event_map, aq_venue_map, aq_performer_map
--   Asset / metadata:      performer_metadata, venue_assets
--   Observability:         cron_policy, cron_gate_decisions
--
-- ============================================================
-- EXPLICITLY NOT IN WHITELIST (Tier 4 — admin-only via service_role)
-- ============================================================
--   Order tables w/ PII:      vivid_orders, evo_orders, seatgeek_orders,
--                             tickpick_orders, evo_order_items
--                             (buyer_name, seller_name, client_name —
--                              expose via SECDEF aggregation RPCs only)
--   Heavy raw row tables:     listings_snapshots (8M rows — perf bomb),
--                             seatgeek_listings_snapshots, event_metrics,
--                             zone_metrics, section_metrics
--                             (expose via SECDEF wrappers when needed)
--   Admin coordination:       bot_chat, bot_chat_threads
--   Network / queue:          pg_net._http_request, net.*, cron_pause_state_*
--   System schemas:           cron.*, vault.*, auth.*  (already locked)
--
-- ============================================================
-- POST-APPLY VERIFICATION
-- ============================================================
-- Run this in the SQL editor as a non-service_role user to confirm:
--
-- SELECT tablename,
--        c.relrowsecurity AS rls_enabled,
--        EXISTS (SELECT 1 FROM pg_policies p
--                WHERE p.schemaname='public' AND p.tablename=c.relname
--                AND p.policyname='d0_s4kent_read') AS has_d0_read_policy
-- FROM pg_class c
-- JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname='public'
--   AND c.relname IN ('events','event_xref','sg_events_canonical',
--                     'aq_event_map','aq_venue_map','aq_performer_map',
--                     'performer_metadata','venue_assets',
--                     'cron_policy','cron_gate_decisions')
-- ORDER BY tablename;
--
-- Expect 10 rows, all with rls_enabled=true and has_d0_read_policy=true.
-- Tables that don't exist in this environment are skipped silently
-- (RAISE NOTICE during apply).

DO $migration$
DECLARE
  v_tables text[] := ARRAY[
    'events',
    'event_xref',
    'sg_events_canonical',
    'aq_event_map',
    'aq_venue_map',
    'aq_performer_map',
    'performer_metadata',
    'venue_assets',
    'cron_policy',
    'cron_gate_decisions'
  ];
  v_t       text;
  v_exists  boolean;
  v_installed int := 0;
  v_skipped int := 0;
BEGIN
  FOREACH v_t IN ARRAY v_tables LOOP
    -- Defensive: skip silently if table doesn't exist in this environment.
    -- Avoids hard failure if a referenced table was renamed or hasn't been
    -- created yet on a branch.
    SELECT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = v_t
    ) INTO v_exists;

    IF NOT v_exists THEN
      RAISE NOTICE 'd0_read_access_grants: skipping missing table public.%', v_t;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- 1. Enable RLS (idempotent; no-op if already enabled).
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', v_t);

    -- 2. Drop existing d0_s4kent_read policy if present (idempotent re-apply).
    EXECUTE format('DROP POLICY IF EXISTS "d0_s4kent_read" ON public.%I', v_t);

    -- 3. Create the email-gated SELECT policy. PERMISSIVE (default) means
    --    this OR's with any existing policies — admin/service_role paths
    --    remain unaffected; @s4kent.com authenticated users gain SELECT.
    EXECUTE format(
      $policy$
      CREATE POLICY "d0_s4kent_read" ON public.%I
        FOR SELECT
        TO authenticated
        USING (coalesce(auth.jwt()->>'email','') LIKE '%%@s4kent.com')
      $policy$,
      v_t
    );

    -- 4. Grant SELECT to authenticated role. Without this, the policy is
    --    moot — RLS only filters rows for roles that have base privilege.
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v_t);

    v_installed := v_installed + 1;
  END LOOP;

  RAISE NOTICE 'd0_read_access_grants: installed % policies, skipped %', v_installed, v_skipped;
END $migration$;

-- Annotate one of the policies as the canonical reference for the convention.
-- (PG doesn't support COMMENT ON POLICY in a portable way across versions,
-- so this is the architecture marker in the migration only — searchable via
-- 'd0_s4kent_read' as the policy name across pg_policies.)
