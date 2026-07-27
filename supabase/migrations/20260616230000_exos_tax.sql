-- ============================================================================
-- Migration 20260616230000 — Exos (Bridge / D4): tax rules / VAT (pretix parity)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_tax_rules (W,new), exos_ticket_tiers (+tax_rate_id),
--           exos_event_addons (+tax_rate_id), exos_checkout_sessions (+tax_cents),
--           exos_public_tax_rules (W,new view); reads exos_events/has_org_role
-- Pre-reqs: 20260520120000 (events/tiers/has_org_role), 20260523170000
--           (checkout sessions), 20260616190000 (event_addons)
--
-- pretix-style reusable TAX RULES (the thin-tax gap both the pretix and
-- hi.events audits flagged). A rule is a named rate + an inclusive/exclusive
-- flag, scoped to an event; tiers and add-ons reference one. The checkout edge
-- fn resolves the rule and either ADDS the tax (exclusive → a separate Stripe
-- "Tax" line) or records the embedded portion (inclusive → price unchanged),
-- writing the computed tax_cents onto the session. Security mirrors phase-1
-- (deny-by-default RLS; anon reads only the published-event public view).
-- D4 authors; A1 applies to prod.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_tax_rules (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id           uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  name               text NOT NULL,                       -- e.g. "VAT 19%", "Sales tax 8.875%"
  rate_percent       numeric NOT NULL CHECK (rate_percent >= 0 AND rate_percent <= 100),
  price_includes_tax boolean NOT NULL DEFAULT false,      -- true = gross (tax embedded); false = added on top
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, name)
);
CREATE INDEX IF NOT EXISTS exos_tax_rules_event_idx ON public.exos_tax_rules (event_id);

DROP TRIGGER IF EXISTS exos_tax_rules_touch ON public.exos_tax_rules;
CREATE TRIGGER exos_tax_rules_touch BEFORE UPDATE ON public.exos_tax_rules
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- Products reference a tax rule (NULL = untaxed). ON DELETE SET NULL so dropping
-- a rule doesn't cascade-delete tiers/add-ons.
ALTER TABLE public.exos_ticket_tiers ADD COLUMN IF NOT EXISTS tax_rate_id uuid
  REFERENCES public.exos_tax_rules (id) ON DELETE SET NULL;
ALTER TABLE public.exos_event_addons ADD COLUMN IF NOT EXISTS tax_rate_id uuid
  REFERENCES public.exos_tax_rules (id) ON DELETE SET NULL;
-- Recorded tax for the order (sum across tier + add-ons).
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS tax_cents integer;

-- ===========================================================================
-- RLS — org staff manage; anon reads only the published-event public view.
-- ===========================================================================
ALTER TABLE public.exos_tax_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY exos_tax_rules_sel_staff ON public.exos_tax_rules FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager','finance','scanner','content'])));
CREATE POLICY exos_tax_rules_wr ON public.exos_tax_rules FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])));
REVOKE ALL ON public.exos_tax_rules FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON public.exos_tax_rules TO authenticated;

-- Buyer-facing: tax rules for published events (so a storefront can show "incl.
-- VAT" / "+ tax"). Owner-run, SELECT only.
CREATE OR REPLACE VIEW public.exos_public_tax_rules AS
  SELECT t.id, t.event_id, t.name, t.rate_percent, t.price_includes_tax
  FROM public.exos_tax_rules t
  JOIN public.exos_events e ON e.id = t.event_id
  WHERE e.status = 'published';
REVOKE ALL ON public.exos_public_tax_rules FROM anon, authenticated;
GRANT  SELECT ON public.exos_public_tax_rules TO anon, authenticated;

-- ===========================================================================
-- Pure tax helper — exclusive: tax on top of net; inclusive: tax embedded in
-- gross. Returns tax in cents. Used by tests + any SQL path that needs it; the
-- edge fn mirrors this arithmetic.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_tax_cents(
  p_amount_cents integer, p_rate_percent numeric, p_price_includes_tax boolean
) RETURNS integer
  LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_rate_percent IS NULL OR p_rate_percent = 0 THEN 0
    WHEN p_price_includes_tax
      THEN round(p_amount_cents * p_rate_percent / (100 + p_rate_percent))::int   -- extract embedded
    ELSE round(p_amount_cents * p_rate_percent / 100)::int                         -- add on top
  END
$$;

COMMENT ON TABLE public.exos_tax_rules IS
  'D4 mig 20260616230000: pretix-style reusable tax rules (rate + inclusive flag),
   referenced by exos_ticket_tiers.tax_rate_id / exos_event_addons.tax_rate_id.
   Checkout computes via exos_tax_cents (exclusive adds a Stripe Tax line;
   inclusive records the embedded portion) and writes session.tax_cents.';
