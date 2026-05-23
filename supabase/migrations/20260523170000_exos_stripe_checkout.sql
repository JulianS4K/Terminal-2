-- ============================================================================
-- Migration 20260523170000 — Exos (Bridge / D4): Stripe checkout + fulfillment
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_checkout_sessions (W, new), exos_fulfill_checkout() (W, new),
--           exos_record_org_stripe() (W, new); reads exos_events/tiers/orgs
-- Pre-reqs: 20260520120000 (orgs/events/tiers/org_secrets),
--           20260520130000 (exos_tickets), 20260523150000 (total_tickets cap)
--
-- D4-OPS-7 — paid purchase flow (SCAFFOLD — Stripe keys + account wired later).
-- Architecture (matches the existing exos_org_secrets.payments shape):
--   Stripe Connect, one connected account per org. Buyer pays via a Checkout
--   Session created on the platform with a destination charge to the org's
--   connected account + an application fee. On `checkout.session.completed` the
--   stripe-webhook edge fn calls exos_fulfill_checkout() to MINT the tickets.
--
-- ⚠ Decisions the operator must confirm before go-live (left as config/TODO in
--   the edge fns, not hardcoded here): Connect account TYPE (Standard/Express),
--   charge model (destination vs direct), application-fee %, success/cancel URLs.
--
-- This migration owns the DATA + the idempotent fulfillment (the real
-- correctness risk — a webhook is retried, must mint exactly once). The edge
-- functions own the Stripe API calls + signature verification.
--
-- D4 authors; A1 applies to prod (AFTER the operator finalizes the Stripe model).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Checkout session ledger. The checkout edge fn inserts a 'pending' row
--    (service_role) keyed on the Stripe session id; the webhook flips it to
--    'fulfilled' after minting. session_id PK = the idempotency key.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_checkout_sessions (
  session_id    text PRIMARY KEY,                       -- Stripe Checkout Session id
  event_id      uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  tier_id       uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  buyer_uid     uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  buyer_email   text,
  quantity      int  NOT NULL CHECK (quantity BETWEEN 1 AND 10),
  amount_cents  int  NOT NULL CHECK (amount_cents >= 0),
  currency      text NOT NULL DEFAULT 'usd',
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','fulfilled','failed','expired')),
  ticket_ids    uuid[],
  payment_intent text,
  failure_reason text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  fulfilled_at  timestamptz
);
CREATE INDEX IF NOT EXISTS exos_checkout_sessions_buyer_idx ON public.exos_checkout_sessions (buyer_uid);
CREATE INDEX IF NOT EXISTS exos_checkout_sessions_event_idx ON public.exos_checkout_sessions (event_id);

ALTER TABLE public.exos_checkout_sessions ENABLE ROW LEVEL SECURITY;
-- Buyer reads their own sessions; org staff read their org's. No client writes
-- (the edge fns write via service_role). anon: nothing.
CREATE POLICY exos_checkout_sel ON public.exos_checkout_sessions FOR SELECT TO authenticated
  USING (buyer_uid = auth.uid()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_checkout_sessions FROM anon, authenticated;
GRANT  SELECT ON public.exos_checkout_sessions TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Idempotent fulfillment. Called by the webhook (service_role) on
--    checkout.session.completed. Mints exactly once per session, honoring the
--    same tier-capacity + event total_tickets caps as exos_mint_tickets.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_fulfill_checkout(p_session_id text)
RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s          public.exos_checkout_sessions%ROWTYPE;
  v_tier_name text;
  v_updated  int;
  v_ids      uuid[] := '{}';
  v_id       uuid;
  i          int;
BEGIN
  -- Lock the session row so concurrent webhook retries serialize.
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: unknown session %', p_session_id;
  END IF;

  -- Already done — return the existing tickets (webhook retry / at-least-once).
  IF s.status = 'fulfilled' THEN
    RETURN coalesce(s.ticket_ids, '{}');
  END IF;
  IF s.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: session % is % (not fulfillable)', p_session_id, s.status;
  END IF;

  -- Tier capacity claim (atomic). NULL tier = no per-tier cap.
  IF s.tier_id IS NOT NULL THEN
    UPDATE public.exos_ticket_tiers
       SET sold = sold + s.quantity
     WHERE id = s.tier_id AND event_id = s.event_id
       AND (capacity = 0 OR sold + s.quantity <= capacity)
    RETURNING name INTO v_tier_name;
    IF NOT FOUND THEN
      UPDATE public.exos_checkout_sessions
         SET status='failed', failure_reason='tier sold out at fulfillment'
       WHERE session_id = p_session_id;
      -- Buyer was charged but tickets unavailable -> caller must refund.
      RAISE EXCEPTION 'exos_fulfill_checkout: tier sold out (session %)', p_session_id;
    END IF;
  END IF;

  -- Event house cap (atomic).
  UPDATE public.exos_events
     SET tickets_sold = tickets_sold + s.quantity
   WHERE id = s.event_id
     AND (total_tickets = 0 OR tickets_sold + s.quantity <= total_tickets);
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    UPDATE public.exos_checkout_sessions
       SET status='failed', failure_reason='event sold out at fulfillment'
     WHERE session_id = p_session_id;
    RAISE EXCEPTION 'exos_fulfill_checkout: event sold out (session %)', p_session_id;
  END IF;

  -- Mint to the buyer.
  FOR i IN 1..s.quantity LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source
    ) VALUES (
      s.event_id, s.org_id, s.tier_id, v_tier_name, s.buyer_uid, s.buyer_uid,
      lower(coalesce(s.buyer_email, '')),
      'active', gen_random_uuid()::text,
      round((s.amount_cents::numeric / 100) / s.quantity, 2),  -- per-ticket paid
      p_session_id, 'stripe'
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  UPDATE public.exos_checkout_sessions
     SET status='fulfilled', ticket_ids=v_ids, fulfilled_at=now()
   WHERE session_id = p_session_id;

  RETURN v_ids;
END $$;
REVOKE ALL ON FUNCTION public.exos_fulfill_checkout(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_fulfill_checkout(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Record an org's Stripe Connect status. Called by the webhook
--    (account.updated) + the onboarding return. service_role only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_org_stripe(
  p_org_id          uuid,
  p_account_id      text,
  p_charges_enabled boolean,
  p_payouts_enabled boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.exos_org_secrets (org_id, payments)
  VALUES (p_org_id, jsonb_build_object(
            'connectedAccountId', p_account_id,
            'chargesEnabled',     p_charges_enabled,
            'payoutsEnabled',     p_payouts_enabled,
            'onboardingComplete', (p_charges_enabled AND p_payouts_enabled)))
  ON CONFLICT (org_id) DO UPDATE
    SET payments = coalesce(public.exos_org_secrets.payments, '{}'::jsonb) || jsonb_build_object(
            'connectedAccountId', p_account_id,
            'chargesEnabled',     p_charges_enabled,
            'payoutsEnabled',     p_payouts_enabled,
            'onboardingComplete', (p_charges_enabled AND p_payouts_enabled)),
        updated_at = now();
END $$;
REVOKE ALL ON FUNCTION public.exos_record_org_stripe(uuid, text, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_org_stripe(uuid, text, boolean, boolean) TO service_role;
