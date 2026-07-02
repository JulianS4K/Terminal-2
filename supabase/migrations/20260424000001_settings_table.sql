-- Migration 20260424000001 · level:security · lane:a1 · writes:settings · reads:- · pre:20260423000000_init
--
-- Reconcile a captured-migration DRIFT surfaced by the migrations-from-zero CI
-- gate (testing-recommendation #1, .github/workflows/supabase-rls.yml).
--
-- `20260425000002_store_github_pat.sql` does `insert into settings ...` and
-- server.py reads TEvo creds from `settings`, but NO committed migration ever
-- created the table — it was made out-of-band in prod (an early Cowork migration
-- never captured into git). So `supabase db start` from an empty database failed
-- with "relation settings does not exist". This migration captures the table so
-- the folder matches prod.
--
-- Idempotent + a NO-OP in prod: `create table if not exists` leaves the existing
-- prod table (and its data) untouched; it only materializes the table in a
-- from-zero environment (CI / preview branch). Schema inferred from every known
-- usage: key (PK, `on conflict (key)`), value, updated_at (`set updated_at =
-- now()`). RLS on with no policies → service_role only (matches the github_pat
-- migration's stated intent; the SECURITY DEFINER cred-read path is unaffected).
--
-- Operator-routed to B1 as part of the review-recommendations branch; A1 owns
-- the prod apply (no-op here).

create table if not exists public.settings (
  key        text primary key,
  value      text,
  updated_at timestamptz not null default now()
);

alter table public.settings enable row level security;

-- No policies + revoke from the PostgREST client roles → only service_role (and
-- the SECURITY DEFINER functions / table owner) can read or write it. The table
-- holds secrets (github_pat, tevo_token/secret), so anon/authenticated must
-- never reach it.
revoke all on public.settings from anon, authenticated;
grant all on public.settings to service_role;
