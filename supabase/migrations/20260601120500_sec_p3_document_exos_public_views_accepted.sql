-- ============================================================
-- SECURITY P3 — document accepted-risk on the exos_public_* SECDEF views (2026-06-01).
-- Operator decision (2026-06-01): LEAVE AS-IS.
--
-- These 3 views are an INTENTIONAL curated public projection. The base tables
-- (exos_events / exos_orgs / exos_ticket_tiers) have RLS enabled and grant anon NOTHING;
-- their only policies are for `authenticated` staff/ticketholders. The exos_public_* views
-- are therefore the sole, safe mechanism by which the public (anon) storefront reads
-- published events, org pages, and public ticket tiers — each filtered to
-- status='published' / visibility='public' with a curated column set.
--
-- The Supabase advisor lint 0010_security_definer_view flags these as ERROR, but that is an
-- ACCEPTED false-positive for this deliberate "curated public projection over RLS-locked
-- base tables" pattern. Do NOT convert to security_invoker without first adding anon SELECT
-- policies on the three base tables that mirror the view WHERE filters — doing so blind would
-- blank the live storefront.
-- ============================================================
COMMENT ON VIEW public.exos_public_events IS
  'Public storefront projection: published events only. SECURITY DEFINER by design (base tables are RLS-locked to staff). Advisor 0010 ERROR accepted — see migration 20260601120500.';
COMMENT ON VIEW public.exos_public_orgs IS
  'Public storefront projection: org public pages. SECURITY DEFINER by design (base tables are RLS-locked to staff). Advisor 0010 ERROR accepted — see migration 20260601120500.';
COMMENT ON VIEW public.exos_public_tiers IS
  'Public storefront projection: public tiers of published events. SECURITY DEFINER by design (base tables are RLS-locked to staff). Advisor 0010 ERROR accepted — see migration 20260601120500.';
