-- ============================================================================
-- 20260511000300 — security: ENABLE RLS on clearly-internal tables
--
-- Background: only ~20 of 136 public tables have RLS enabled. Tables without
-- RLS are reachable via PostgREST with the anon JWT (which is published in
-- /api/public/config + edge fn migrations). This migration enables RLS on
-- *operational* tables that should never be reached by anon — queues, pull
-- logs, crawl state, internal audit tables.
--
-- Approach: dynamic ALTER TABLE on every public table whose name matches one
-- of the well-known internal suffixes/prefixes AND that doesn't already have
-- RLS. NO policies are added — RLS with no policy = service_role only, which
-- is what we want for these tables.
--
-- Domain tables (events, performers, listings_snapshots, etc.) are NOT
-- touched here — they need explicit per-table policy decisions and are
-- tracked under the separate SEC-HIGH "RLS coverage audit" entry.
--
-- Safe to re-run: ALTER TABLE ... ENABLE RLS is idempotent.
--
-- Filed by: A1 · 2026-05-11 security chat · SEC-HIGH entry in KANBAN.md.
-- ============================================================================

DO $$
DECLARE
  r record;
  -- Pattern allowlist — these are clearly internal/operational. If you add
  -- a table whose name doesn't end in one of these, it MUST get an explicit
  -- RLS decision (and ideally a policy) elsewhere.
  _patterns text[] := ARRAY[
    '%_pending',         -- queue tables (fred_pending, espn_scoreboard_pending, ...)
    '%_pull_log',        -- API call logs
    '%_pull_budget',     -- budget counters
    '%_crawl_state',     -- crawl/seed state machines
    '%_snapshots_pending',
    '%_rate_limits',     -- pull_rate_limits, chat_rate_limits
    '%_audit_findings',  -- chat_audit_findings
    '%_match_attempts',  -- event_match_attempts
    '%_xref',            -- cross-source mapping (internal IDs)
    '%_runs',            -- runs, espn_runs
    '%_baselines',       -- performer_baselines
    '%_metadata',        -- performer_metadata (mostly internal enrichment)
    '%_staging',         -- code_staging
    '%_test',            -- copilot_test, design_test
    'event_alerts',
    'event_sentiment',
    'event_pulls',
    'event_competitors_snapshot',
    'order_fee_schedule',
    'order_status_xref',
    'data_source_field_map',
    'data_sources',
    'general_subreddits',
    'important_x_accounts',
    'news_keywords',
    'school_break_windows',
    'holidays',
    'major_event_calendar',
    'mlb_branded_series',
    'macro_series_config'
  ];
BEGIN
  FOR r IN
    SELECT c.relname AS tablename
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relrowsecurity = false
      AND EXISTS (
        SELECT 1 FROM unnest(_patterns) AS p WHERE c.relname LIKE p
      )
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.tablename);
    RAISE NOTICE 'security: RLS enabled on public.%', r.tablename;
  END LOOP;
END $$;

-- Also FORCE RLS on the `leads` table — it has policies but service_role can
-- bypass even with FORCE only enforced for the table owner role. Adding
-- FORCE makes the deny-by-default story explicit for non-superuser.
-- (No-op if already forced.)
ALTER TABLE IF EXISTS public.leads FORCE ROW LEVEL SECURITY;
