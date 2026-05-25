-- ============================================================================
-- Migration 20260524120000 — Exos (Bridge / D4): expose public marketing config
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_public_orgs (view: +marketing)
-- Pre-reqs: 20260520140000 (exos_public_orgs +description/+followers_count),
--           20260523200000 (exos_orgs.marketing jsonb)
--
-- The growth-primitives migration (20260523200000) deliberately deferred adding
-- `marketing` to the public view pending a CSP/consent review. That review is
-- resolved on the client side: pixels load only behind an explicit consent gate
-- (d4_bridge lib/consent.ts + ConsentBanner), and the snippets are the vendors'
-- standard public loaders. The `marketing` jsonb is public-by-construction —
-- social handles + client-side pixel IDs (fbq/gtag/ttq), no secrets — so it is
-- safe to surface to anon storefront/event readers.
--
-- D4 authors; validate on a Supabase preview branch; A1 applies to prod.
-- ============================================================================

CREATE OR REPLACE VIEW public.exos_public_orgs AS
  SELECT id, name, slug, theme, description, followers_count, marketing
  FROM public.exos_orgs;

-- Auto-updatable views inherit GRANT ALL → anon; keep the boundary read-only.
REVOKE ALL ON public.exos_public_orgs FROM anon, authenticated;
GRANT  SELECT ON public.exos_public_orgs TO anon, authenticated;
