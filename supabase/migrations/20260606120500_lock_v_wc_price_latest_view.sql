-- Security remediation (2026-06-06, follow-up to 20260606120000):
-- v_wc_price_latest is a SECURITY DEFINER view over wc_price_daily that
-- exposed our owned-inventory metrics (owned_listings/owned_tickets, price
-- percentiles) to anon — and, being SECDEF, bypassed the RLS we just enabled
-- on wc_price_daily. It is referenced nowhere outside its own creating
-- migration (no frontend / app.py / edge function reads it), so it is an
-- internal analytics view that was unintentionally anon-readable.
--
-- Fix: switch to security_invoker (so the querying user's RLS applies) and
-- restrict to authenticated staff. The 3 exos_public_* views are deliberately
-- SECURITY DEFINER public-embed reads (curated columns, published-only) and
-- are intentionally left unchanged.
ALTER VIEW public.v_wc_price_latest SET (security_invoker = on);
REVOKE SELECT ON public.v_wc_price_latest FROM PUBLIC, anon;
GRANT SELECT ON public.v_wc_price_latest TO authenticated;
