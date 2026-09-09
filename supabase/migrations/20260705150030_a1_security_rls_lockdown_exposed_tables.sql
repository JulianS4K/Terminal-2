-- ============================================================================
-- Migration 20260705150030 — RLS lockdown: 5 exposed tables + default privs
--
-- Lane:     A1 (DB security / Auditor)
-- Touches:  cast_price_ref (W), espn_scratch_dbg (W), reddit_news_pending (W),
--           trend_poll_state (W), tsa_pending (W), pg_default_acl (W)
-- Pre-reqs: none
--
-- Applied to prod 2026-07-05 via MCP (operator-directed supabase-audit
-- session); idempotent on replay.
--
-- These 5 public tables had RLS disabled while anon/authenticated held full
-- CRUD (incl. TRUNCATE) via PostgREST — anyone with the publishable anon JWT
-- could read/write/truncate them. Writers verified service-role or
-- postgres-owned cron SQL only (trends-collect edge fn uses
-- SUPABASE_SERVICE_ROLE_KEY; zero references in static/); enabling RLS +
-- revoking public-role grants does not affect them.
--
-- Also revokes the schema-level DEFAULT grant of full CRUD to
-- anon/authenticated on FUTURE tables created by postgres in public — the
-- systemic root cause (a forgotten-RLS table was world-writable by default).
-- Intentionally-public tables now need an explicit GRANT + RLS policy.
-- Residual: tables created by supabase_admin keep that role's defaults
-- (cannot ALTER another role's default privileges from postgres).
-- ============================================================================

alter table public.cast_price_ref enable row level security;
alter table public.espn_scratch_dbg enable row level security;
alter table public.reddit_news_pending enable row level security;
alter table public.trend_poll_state enable row level security;
alter table public.tsa_pending enable row level security;

revoke all on table
  public.cast_price_ref,
  public.espn_scratch_dbg,
  public.reddit_news_pending,
  public.trend_poll_state,
  public.tsa_pending
from anon, authenticated;

alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on tables from authenticated;
