-- ============================================================================
-- Migration 20260925000000 — Exos (Bridge / D4): a voucher can reveal the
--                            hidden tier it unlocks
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_voucher_tier (new)
--           R: exos_check_voucher, exos_ticket_tiers, exos_events, exos_tier_exclusive_tax_percent
-- Pre-reqs: 20260616210000 (exos_check_voucher), 20260924211840 (exclusive_tax_percent)
--
-- Bug (review 2026-09-25). Hidden tiers are sold only through a voucher
-- restricted to them, and exos-checkout enforces that. But the storefront
-- reads tiers from exos_public_tiers, which is public-only, so a buyer who
-- entered a valid code never saw the tier: the page kept tier 0 selected and
-- checkout either charged tier 0 or was rejected. Promoter buy-now links for
-- hidden tiers (EXP PromoterKitPanel) hit the same wall.
-- exos_voucher_tier returns that one tier's buyer-safe fields, same columns
-- and order as exos_public_tiers, only when the voucher is valid for this
-- event (exos_check_voucher decides: uses left, expiry, reserved email) and
-- the event is published. No voucher, no row.
--
-- Idempotent. D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_voucher_tier(p_event_id uuid, p_code text, p_email text DEFAULT NULL)
RETURNS TABLE (
  id uuid, event_id uuid, name text, description text, price numeric, capacity integer, sold integer,
  ticket_type text, sales_start timestamptz, sales_end timestamptz, sort_order integer,
  price_schedule jsonb, exclusive_tax_percent numeric
)
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT t.id, t.event_id, t.name, t.description, t.price, t.capacity, t.sold,
         t.ticket_type, t.sales_start, t.sales_end, t.sort_order, t.price_schedule,
         public.exos_tier_exclusive_tax_percent(t.id)
  FROM public.exos_check_voucher(p_event_id, p_code, p_email) v
  JOIN public.exos_ticket_tiers t ON t.id = v.restrict_tier_id
  JOIN public.exos_events e ON e.id = t.event_id
  WHERE v.is_valid AND t.event_id = p_event_id AND e.status = 'published';
$$;
REVOKE ALL ON FUNCTION public.exos_voucher_tier(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_voucher_tier(uuid, text, text) TO anon, authenticated, service_role;
