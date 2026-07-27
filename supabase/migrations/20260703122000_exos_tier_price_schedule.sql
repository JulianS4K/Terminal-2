-- ============================================================================
-- Migration 20260703122000 — Exos (Bridge / D4): scheduled tier pricing
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_ticket_tiers (W: +price_schedule jsonb),
--           exos_public_tiers (view: +price_schedule column, security_invoker),
--           anon column-grant on exos_ticket_tiers (+price_schedule)
-- Pre-reqs: 20260520120000 (exos_ticket_tiers + exos_public_tiers),
--            20260622210000 (public views → security_invoker + anon column grants).
--
-- Seller-side revenue tooling — the "dynamic pricing" gap vs Ticketmaster /
-- SeatGeek, scoped to a demand-agnostic v1: TIME-BASED price steps (early-bird →
-- regular → last-minute). `price` stays the opening/default price; price_schedule
-- is an ordered array of {startsAt, price} overrides. The EFFECTIVE price at any
-- moment = the price of the latest step whose starts_at <= now() (or the base
-- price if none apply). Computed at read time (no cron) — the storefront shows
-- the current price and a "price rises on <date>" nudge.
--
-- ⚠ NOT a RULE-2 concern. RULE-2's no-reprice lockdown is about UPSTREAM broker
--   listing sources (the GET-only *_client.py). This changes the price of OUR OWN
--   primary-market inventory (exos_ticket_tiers) in our own DB and never touches
--   any upstream API — repricing our own event is exactly what a primary ticketer
--   does. (Server-side charge enforcement lands with the exos-checkout wiring,
--   which must recompute the effective price server-side; v1 is display + editor.)
--
-- Writes go through the existing org-staff RLS on exos_ticket_tiers (the tier
-- editor already UPDATEs the row) — no new RPC. Reads are public: buyers need the
-- schedule to see the live price, so it rides the exos_public_tiers boundary.
--
-- D4 authors; A1 applies (public storefront read boundary — D4 + A1 review).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The schedule column. Array of {starts_at: iso, price: number} steps. The
--    CHECK guarantees array-ness; per-entry shape is validated by the editor +
--    the read-time helper (a malformed entry is simply ignored client-side).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_ticket_tiers
  ADD COLUMN IF NOT EXISTS price_schedule jsonb NOT NULL DEFAULT '[]'::jsonb
  CONSTRAINT exos_ticket_tiers_price_schedule_is_array
    CHECK (jsonb_typeof(price_schedule) = 'array');

-- ---------------------------------------------------------------------------
-- 2. Expose it through the public tiers view. The view is security_invoker
--    (mig 20260622210000): row visibility comes from the base-table RLS
--    (exos_tiers_public_read) and anon reads via a COLUMN-scoped grant, so the
--    new column must be added to that grant too. authenticated has table-wide
--    SELECT on the base table, so it needs no column change.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_public_tiers AS
  SELECT t.id, t.event_id, t.name, t.description, t.price, t.capacity, t.sold,
         t.ticket_type, t.sales_start, t.sales_end, t.sort_order, t.price_schedule
  FROM public.exos_ticket_tiers t
  JOIN public.exos_events e ON e.id = t.event_id
  WHERE t.visibility = 'public' AND e.status = 'published';

-- CREATE OR REPLACE can reset view options — re-assert security_invoker so the
-- JOIN + base-table RLS keep running as the caller (not the view owner).
ALTER VIEW public.exos_public_tiers SET (security_invoker = true);

-- Re-assert the SELECT-only view grant (owner-run-view landmine: auto GRANT ALL
-- → anon on replace). Whole-view SELECT is correct — every projected column is
-- public storefront data.
REVOKE ALL ON public.exos_public_tiers FROM anon, authenticated;
GRANT SELECT ON public.exos_public_tiers TO anon, authenticated;

-- Extend the anon column-scoped grant on the base table with price_schedule
-- (idempotent — re-granting the full set the security_invoker migration set,
-- plus the new column).
GRANT SELECT (id, event_id, name, description, price, capacity, sold,
              ticket_type, sales_start, sales_end, sort_order, visibility,
              price_schedule)
  ON public.exos_ticket_tiers TO anon;

COMMENT ON COLUMN public.exos_ticket_tiers.price_schedule IS
  'D4 mig 20260703122000: ordered [{startsAt,price}] time-based price steps.
   Effective price = latest step with starts_at<=now(), else base price. Read-time
   computed (lib/pricing.ts). Own primary inventory — not a RULE-2 upstream reprice.';
