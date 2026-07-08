-- ============================================================================
-- Migration 20260709120100 — Exos (Bridge / D4): org country + currency
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_orgs (W: +country, +currency)
-- Pre-reqs: 20260520120000 (exos_orgs base table).
--
-- Backs the CreateOrg/OrgSettings country + currency fields (the mockup had
-- them but there was no backing column). Additive, nullable-with-default —
-- existing rows default to a US/USD baseline and every read keeps working.
-- These are org-level defaults surfaced in settings; event-level currency
-- (exos_events.currency) is unaffected.
--
-- Not exposed on exos_public_orgs (the anon projection) — org locale is
-- settings metadata, not public storefront data.
--
-- ⚠ D4 authors; validate on a Supabase preview branch; apply to prod is the
-- gated Applier step (CLAUDE.md Rule 1). Not yet applied to prod.
-- ============================================================================

-- ISO 3166-1 alpha-2 country code (e.g. 'US'); ISO 4217 currency (e.g. 'USD').
-- Defaults keep every existing org valid and every read backward-compatible.
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS country  text NOT NULL DEFAULT 'US';
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'USD';
