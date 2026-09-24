-- ============================================================================
-- Migration 20260924211840 — Exos (Bridge / D4): all-in pricing — the
--                            storefront can see the tax it has to include
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_tier_exclusive_tax_percent, exos_addon_exclusive_tax_percent (new);
--              VIEW exos_public_tiers, exos_public_addons (+exclusive_tax_percent, appended)
--           R: exos_ticket_tiers, exos_event_addons, exos_tax_rules, exos_events
-- Pre-reqs: 20260616230000 (tax rules), 20260616190000 (exos_public_addons),
--           20260703122000 (latest exos_public_tiers)
--
-- Operator decision 2026-09-24: all-in pricing. Every price a buyer sees is the
-- full amount they pay (the FTC's live-event fee rule points the same way).
-- Buyers pay no service fee (the platform fee comes out of the organizer's
-- share), so the only thing checkout adds is EXCLUSIVE tax — and the storefront
-- couldn't show it: exos_tax_rules is staff-only and the public views didn't
-- expose a rate. These two helpers return just the exclusive rate (0 when the
-- price already includes tax or there's no rule); the public views append it
-- as `exclusive_tax_percent`. The all-in unit price is then
-- price + round(price_cents * rate / 100), computed identically by the SPA and
-- exos-checkout (supabase/functions/_shared/pricing.ts).
--
-- The helpers are SECURITY DEFINER so anon doesn't need grants on
-- exos_tax_rules or on exos_ticket_tiers.tax_rate_id; a tax rate is public
-- information by nature (it's on the receipt).
--
-- Idempotent: CREATE OR REPLACE; view columns appended at the end.
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_tier_exclusive_tax_percent(p_tier_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE((
    SELECT r.rate_percent
      FROM public.exos_ticket_tiers t
      JOIN public.exos_tax_rules r ON r.id = t.tax_rate_id
     WHERE t.id = p_tier_id AND NOT r.price_includes_tax
  ), 0)
$$;
REVOKE ALL ON FUNCTION public.exos_tier_exclusive_tax_percent(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_tier_exclusive_tax_percent(uuid) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_addon_exclusive_tax_percent(p_addon_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE((
    SELECT r.rate_percent
      FROM public.exos_event_addons a
      JOIN public.exos_tax_rules r ON r.id = a.tax_rate_id
     WHERE a.id = p_addon_id AND NOT r.price_includes_tax
  ), 0)
$$;
REVOKE ALL ON FUNCTION public.exos_addon_exclusive_tax_percent(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_addon_exclusive_tax_percent(uuid) TO anon, authenticated, service_role;

-- Same body as 20260703122000 + one appended column.
CREATE OR REPLACE VIEW public.exos_public_tiers AS
  SELECT t.id, t.event_id, t.name, t.description, t.price, t.capacity, t.sold,
         t.ticket_type, t.sales_start, t.sales_end, t.sort_order, t.price_schedule,
         public.exos_tier_exclusive_tax_percent(t.id) AS exclusive_tax_percent
  FROM public.exos_ticket_tiers t
  JOIN public.exos_events e ON e.id = t.event_id
  WHERE t.visibility = 'public' AND e.status = 'published';
ALTER VIEW public.exos_public_tiers SET (security_invoker = true);
REVOKE ALL ON public.exos_public_tiers FROM anon, authenticated;
GRANT SELECT ON public.exos_public_tiers TO anon, authenticated;

-- Same body as 20260616190000 + one appended column (definer view, as before).
CREATE OR REPLACE VIEW public.exos_public_addons AS
  SELECT a.id, a.event_id, a.name, a.description, a.price, a.capacity, a.sold,
         a.max_per_order, a.image_url, a.sort_order,
         public.exos_addon_exclusive_tax_percent(a.id) AS exclusive_tax_percent
  FROM public.exos_event_addons a
  JOIN public.exos_events e ON e.id = a.event_id
  WHERE a.visibility = 'public' AND e.status = 'published';
REVOKE ALL ON public.exos_public_addons FROM anon, authenticated;
GRANT  SELECT ON public.exos_public_addons TO anon, authenticated;
