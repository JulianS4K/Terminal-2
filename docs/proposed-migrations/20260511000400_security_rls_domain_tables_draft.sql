-- ============================================================================
-- 20260511000400 — security: ENABLE RLS on domain tables (DRAFT — verify first)
--
-- LOCATION: docs/proposed-migrations/ (NOT supabase/migrations/). Kept out of
-- the auto-apply path on purpose — `supabase db push` will NOT pick this up.
-- After B1 verifies §C against prod, COPY this file into supabase/migrations/
-- (filename can stay the same) and re-run db push. Moved here 2026-05-11
-- per B1 blocker on PR #57.
--
-- Lane:     xref+macro (audit / security)
-- Touches:  every public.* table not already RLS-enabled, with explicit
--           anon-read carve-outs for the documented public surface.
-- Pre-reqs: 20260511000300 (operational tables already locked down)
--
-- *** DRAFT — DO NOT APPLY WITHOUT B1 VERIFICATION ***
--
-- Why this is DRAFT, not direct-apply:
--
-- The 2026-05-10 audit found ~120 of 141 public tables had RLS off, meaning
-- the anon role (whose JWT is published in /api/public/config + the cron
-- migrations) could SELECT/INSERT/UPDATE/DELETE on every one via PostgREST.
--
-- Migration 20260511000300 swept the OPERATIONAL tables (queues, logs, crawl
-- state) using a name-pattern allowlist. This migration covers the DOMAIN
-- tables (events, performers, listings, etc.) with explicit per-table policy
-- decisions. The decisions encode what we believe the current effective
-- behavior to be:
--
--   1. Public catalog tables — anon SELECT only (matches today's PostgREST behavior)
--   2. Internal operational tables not caught by 20260511000300 — service_role only
--   3. User-scoped tables — service_role only (FastAPI mediates per-user access)
--
-- B1: BEFORE applying, run the verification block at the bottom of this file
-- against prod. Confirm every table in the lockdown set really is unused by
-- anon. If a table the app expects to be anon-readable gets locked, the
-- symptom is silent empty arrays (PostgREST returns 0 rows under RLS) — not
-- a 500. So the app may *appear* to work while data quietly disappears.
--
-- Filed by: A1 · 2026-05-11 security chat · SEC-HIGH entry in KANBAN.md.
-- ============================================================================

-- ----------------------------------------------------------------------
-- (A) Public catalog — anon + authenticated SELECT (matches existing GRANT)
-- ----------------------------------------------------------------------
-- These tables represent the storefront-facing public catalog. Today they're
-- reachable without RLS; this section preserves that with an explicit
-- policy so future RLS-on-by-default doesn't silently lock the storefront.

DO $$
DECLARE
  r record;
  _public_read text[] := ARRAY[
    'events',                  -- TEvo event catalog
    'performers',              -- TEvo performer catalog
    'venues',                  -- TEvo venue catalog
    'configurations',          -- TEvo seating configs
    -- listings_snapshots, event_xref, espn_event_snapshots, venue_assets
    -- already have explicit anon policies from earlier migrations — skip.
    'performer_metadata',      -- ESPN enrichment (team logos / colors)
    'espn_teams_canonical',    -- canonical team list (used by retail)
    'espn_athletes'            -- public roster info
  ];
BEGIN
  FOR r IN
    SELECT c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relname = ANY(_public_read)
      AND c.relrowsecurity = false
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.tablename);
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I',
      r.tablename || '_anon_read', r.tablename
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO anon, authenticated USING (true)',
      r.tablename || '_anon_read', r.tablename
    );
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I',
      r.tablename || '_service_all', r.tablename
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)',
      r.tablename || '_service_all', r.tablename
    );
    RAISE NOTICE 'security: anon-read policy on public.%', r.tablename;
  END LOOP;
END $$;

-- ----------------------------------------------------------------------
-- (B) Lockdown — RLS on with NO policy = service_role only
-- ----------------------------------------------------------------------
-- Sweeps every remaining public.* table that's still RLS-off. Service-role
-- callers (the FastAPI app, edge functions) keep working because the
-- service_role bypasses RLS by design. Anon callers (PostgREST direct)
-- get back zero rows.

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relrowsecurity = false
      -- Don't touch tables explicitly carved out elsewhere
      AND c.relname NOT IN (
        'venue_assets',           -- has anon policy in 20260508140000
        'espn_event_snapshots',   -- has anon policy in 20260510020000
        'event_xref',             -- has anon policy in 20260510020000
        'listings_snapshots',     -- has anon policy in 20260510020000
        'leads'                   -- has anon-INSERT policy in 20260508023000
      )
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.tablename);
    -- No policies created → only service_role can read/write.
    RAISE NOTICE 'security: RLS lockdown on public.%', r.tablename;
  END LOOP;
END $$;

-- ----------------------------------------------------------------------
-- (C) VERIFICATION (B1: run against prod BEFORE applying)
-- ----------------------------------------------------------------------
-- Paste the queries below into the Supabase SQL editor connected to PROD.
-- Compare the outputs to what this migration assumes.
--
--   -- 1. Tables that are RLS-off today (this migration's input set):
--   SELECT n.nspname, c.relname
--   FROM pg_class c
--   JOIN pg_namespace n ON n.oid = c.relnamespace
--   WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity
--   ORDER BY c.relname;
--
--   -- 2. Tables that anon currently has any GRANT on (might break if locked):
--   SELECT table_name, privilege_type
--   FROM information_schema.role_table_grants
--   WHERE grantee = 'anon' AND table_schema = 'public'
--   ORDER BY table_name, privilege_type;
--
--   -- 3. Tables actually queried with anon JWT in the last 7 days
--   --    (requires Supabase Logs UI — Filter: status_code 200 + role anon):
--   --    Look at pg_stat_statements or the Logs Explorer for hits keyed on
--   --    anon role. Any table that shows up there must NOT be in the lockdown
--   --    set OR must get an explicit anon-read policy added BEFORE applying.
--
-- If verification surfaces a table that shouldn't be locked, add it to set (A)
-- BEFORE applying.
--
-- After applying, monitor for empty PostgREST responses for ~24h. Symptoms of
-- over-locking: API endpoints that previously returned data now return [].
-- Recovery: identify the table, add an explicit anon-read policy, re-apply.
--
-- ============================================================================
