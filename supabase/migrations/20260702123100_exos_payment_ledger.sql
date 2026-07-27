-- ============================================================================
-- Migration 20260702123100 — Exos (Bridge / D4): payment + refund ledger
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_order_payments (W, new), exos_order_refunds (W, new),
--           exos_record_payment() / exos_record_refund() (W, new),
--           exos_checkout_sessions.status CHECK (ALTER — adds 'partially_refunded');
--           reads exos_checkout_sessions.
-- Pre-reqs: 20260523170000 (exos_checkout_sessions + exos_refund_checkout)
--
-- TIER-1 pretix-parity feature #3 (CLEAN-ROOM — AGPL fence per the holds header;
-- original implementation of the *concept*, no pretix code). pretix models
-- Order → OrderPayment(s) → OrderRefund(s) as first-class STATEFUL rows rather
-- than a status string on the order. That shape is what makes partial refunds,
-- failed-then-retried payments, and webhook reconciliation fall out naturally.
--
-- TODAY exos_checkout_sessions carries a single `payment_intent text` + a coarse
--   status, and exos_refund_checkout() explicitly voids the WHOLE order (partial
--   refunds "out of scope for v1"). This adds the ledger so those become
--   expressible BEFORE Stripe goes live (retrofitting a ledger after real money
--   has moved means back-deriving history from Stripe — the analysis's warning).
--
-- RELATION to the existing row: additive. exos_checkout_sessions stays the
--   order/fulfillment record (the mint idempotency key); these tables are the
--   money sub-ledger keyed to it. The session `status` gains 'partially_refunded'
--   so a partial refund has a coarse state too, without disturbing the
--   'pending'/'fulfilled'/'refunded' transitions exos_fulfill_checkout relies on.
--
-- INTEGRATION (follow-up, D4-owned edge code — documented, not done here): the
--   stripe-webhook edge fn calls exos_record_payment() on
--   payment_intent.succeeded/failed and exos_record_refund() on charge.refunded /
--   refund.updated. A partial exos_record_refund() can drive a partial void once
--   exos_refund_checkout is extended to a per-ticket refund; kept full-order here.
--
-- D4 authors; validate on a Supabase preview branch; A1 applies to prod.
-- ⚠ B1 review requested on the RLS model + the status CHECK alter.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Payments. One row per Stripe PaymentIntent attempt against a session. A
--    failed-then-retried checkout yields multiple rows; the succeeded one is the
--    money of record. Idempotency: unique on (provider, payment_intent) so a
--    retried webhook UPSERTs the same row instead of duplicating.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_order_payments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id       text NOT NULL REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id)   ON DELETE CASCADE,
  event_id         uuid REFERENCES public.exos_events (id)          ON DELETE SET NULL,
  buyer_uid        uuid REFERENCES auth.users (id)                  ON DELETE SET NULL,
  provider         text NOT NULL DEFAULT 'stripe',
  payment_intent   text,                                            -- Stripe PaymentIntent id
  charge_id        text,                                            -- Stripe Charge id
  amount_cents     int  NOT NULL CHECK (amount_cents >= 0),
  currency         text NOT NULL DEFAULT 'usd',
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','processing','succeeded','failed','canceled')),
  failure_reason   text,
  provider_event_id text,                                           -- last Stripe event id applied (audit)
  meta             jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_order_payments_session_idx ON public.exos_order_payments (session_id);
CREATE INDEX IF NOT EXISTS exos_order_payments_org_idx     ON public.exos_order_payments (org_id);
CREATE INDEX IF NOT EXISTS exos_order_payments_buyer_idx   ON public.exos_order_payments (buyer_uid);
-- Partial-unique idempotency keys (only when the id is present).
CREATE UNIQUE INDEX IF NOT EXISTS exos_order_payments_pi_uq
  ON public.exos_order_payments (provider, payment_intent) WHERE payment_intent IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_order_payments_charge_uq
  ON public.exos_order_payments (charge_id) WHERE charge_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Refunds. One row per Stripe Refund object. amount_cents < the payment's
--    amount ⇒ is_partial. Idempotency: unique on refund_id.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_order_refunds (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id       uuid REFERENCES public.exos_order_payments (id) ON DELETE SET NULL,
  session_id       text NOT NULL REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  provider         text NOT NULL DEFAULT 'stripe',
  refund_id        text,                                            -- Stripe Refund id
  amount_cents     int  NOT NULL CHECK (amount_cents >= 0),
  currency         text NOT NULL DEFAULT 'usd',
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','succeeded','failed','canceled')),
  reason           text,
  is_partial       boolean NOT NULL DEFAULT false,
  provider_event_id text,
  meta             jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_order_refunds_session_idx ON public.exos_order_refunds (session_id);
CREATE INDEX IF NOT EXISTS exos_order_refunds_payment_idx ON public.exos_order_refunds (payment_id);
CREATE INDEX IF NOT EXISTS exos_order_refunds_org_idx     ON public.exos_order_refunds (org_id);
CREATE UNIQUE INDEX IF NOT EXISTS exos_order_refunds_rid_uq
  ON public.exos_order_refunds (refund_id) WHERE refund_id IS NOT NULL;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_order_payments','exos_order_refunds'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON public.%I
         FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Allow a 'partially_refunded' coarse state on the session. Additive: the
--    existing 'pending'/'fulfilled'/'failed'/'expired'/'refunded' transitions in
--    exos_fulfill_checkout / exos_refund_checkout are untouched; reconciliation
--    sets this new value when refunds sum to less than the amount paid.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions DROP CONSTRAINT IF EXISTS exos_checkout_sessions_status_check;
ALTER TABLE public.exos_checkout_sessions
  ADD CONSTRAINT exos_checkout_sessions_status_check
  CHECK (status IN ('pending','fulfilled','failed','expired','refunded','partially_refunded'));

-- ---------------------------------------------------------------------------
-- 4. Record/UPSERT a payment. service_role only (the webhook). Idempotent on
--    (provider, payment_intent): a duplicate delivery updates status/charge in
--    place. Returns the payment row id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_payment(
  p_session_id       text,
  p_payment_intent   text,
  p_amount_cents     int,
  p_status           text,
  p_charge_id        text  DEFAULT NULL,
  p_currency         text  DEFAULT 'usd',
  p_failure_reason   text  DEFAULT NULL,
  p_provider_event_id text DEFAULT NULL,
  p_meta             jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s   public.exos_checkout_sessions%ROWTYPE;
  v_id uuid;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_record_payment: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('pending','processing','succeeded','failed','canceled') THEN
    RAISE EXCEPTION 'exos_record_payment: invalid status %', p_status;
  END IF;

  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_record_payment: unknown session %', p_session_id;
  END IF;

  INSERT INTO public.exos_order_payments (
    session_id, org_id, event_id, buyer_uid, provider, payment_intent, charge_id,
    amount_cents, currency, status, failure_reason, provider_event_id, meta
  ) VALUES (
    p_session_id, s.org_id, s.event_id, s.buyer_uid, 'stripe', p_payment_intent, p_charge_id,
    p_amount_cents, lower(coalesce(p_currency, 'usd')), p_status,
    left(p_failure_reason, 500), p_provider_event_id, p_meta
  )
  ON CONFLICT (provider, payment_intent) WHERE payment_intent IS NOT NULL
  DO UPDATE SET
    status            = EXCLUDED.status,
    charge_id         = COALESCE(EXCLUDED.charge_id, public.exos_order_payments.charge_id),
    amount_cents      = EXCLUDED.amount_cents,
    failure_reason    = EXCLUDED.failure_reason,
    provider_event_id = EXCLUDED.provider_event_id,
    meta              = COALESCE(EXCLUDED.meta, public.exos_order_payments.meta)
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_payment(text, text, int, text, text, text, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_payment(text, text, int, text, text, text, text, text, jsonb)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Record/UPSERT a refund. service_role only. Idempotent on refund_id. Links
--    to the payment via payment_intent when known, stamps is_partial by comparing
--    to the linked payment's amount, and reconciles the session's coarse status:
--    refunds summing to >= amount paid ⇒ 'refunded', a positive lesser sum ⇒
--    'partially_refunded'. Returns the refund row id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_refund(
  p_session_id       text,
  p_refund_id        text,
  p_amount_cents     int,
  p_status           text,
  p_payment_intent   text  DEFAULT NULL,
  p_reason           text  DEFAULT NULL,
  p_currency         text  DEFAULT 'usd',
  p_provider_event_id text DEFAULT NULL,
  p_meta             jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s          public.exos_checkout_sessions%ROWTYPE;
  v_pay      public.exos_order_payments%ROWTYPE;
  v_partial  boolean := false;
  v_id       uuid;
  v_refunded int;
  v_paid     int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_record_refund: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('pending','succeeded','failed','canceled') THEN
    RAISE EXCEPTION 'exos_record_refund: invalid status %', p_status;
  END IF;

  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_record_refund: unknown session %', p_session_id;
  END IF;

  -- Link to the originating payment (by intent, else the session's succeeded one).
  IF p_payment_intent IS NOT NULL THEN
    SELECT * INTO v_pay FROM public.exos_order_payments
     WHERE provider = 'stripe' AND payment_intent = p_payment_intent;
  END IF;
  IF v_pay.id IS NULL THEN
    SELECT * INTO v_pay FROM public.exos_order_payments
     WHERE session_id = p_session_id AND status = 'succeeded'
     ORDER BY amount_cents DESC LIMIT 1;
  END IF;
  IF v_pay.id IS NOT NULL AND p_amount_cents < v_pay.amount_cents THEN
    v_partial := true;
  END IF;

  INSERT INTO public.exos_order_refunds (
    payment_id, session_id, org_id, provider, refund_id, amount_cents, currency,
    status, reason, is_partial, provider_event_id, meta
  ) VALUES (
    v_pay.id, p_session_id, s.org_id, 'stripe', p_refund_id, p_amount_cents,
    lower(coalesce(p_currency, 'usd')), p_status, left(p_reason, 500), v_partial,
    p_provider_event_id, p_meta
  )
  ON CONFLICT (refund_id) WHERE refund_id IS NOT NULL
  DO UPDATE SET
    status            = EXCLUDED.status,
    amount_cents      = EXCLUDED.amount_cents,
    is_partial        = EXCLUDED.is_partial,
    reason            = EXCLUDED.reason,
    provider_event_id = EXCLUDED.provider_event_id,
    meta              = COALESCE(EXCLUDED.meta, public.exos_order_refunds.meta)
  RETURNING id INTO v_id;

  -- Reconcile the session's coarse status from SUCCEEDED refunds vs amount paid.
  -- Never downgrade a fully-'refunded' session (a later partial event can't undo it).
  IF s.status <> 'refunded' THEN
    SELECT COALESCE(SUM(amount_cents), 0) INTO v_refunded
      FROM public.exos_order_refunds WHERE session_id = p_session_id AND status = 'succeeded';
    v_paid := s.amount_cents;
    IF v_refunded > 0 THEN
      UPDATE public.exos_checkout_sessions
         SET status = CASE WHEN v_refunded >= v_paid THEN 'refunded' ELSE 'partially_refunded' END
       WHERE session_id = p_session_id;
    END IF;
  END IF;

  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_refund(text, text, int, text, text, text, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_refund(text, text, int, text, text, text, text, text, jsonb)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 6. RLS. Buyer reads their own money rows; org finance/owner/manager read the
--    org's. No client writes (webhook via service_role). anon: nothing.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_order_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_order_refunds  ENABLE ROW LEVEL SECURITY;

CREATE POLICY exos_order_payments_sel ON public.exos_order_payments FOR SELECT TO authenticated
  USING (buyer_uid = auth.uid()
         OR exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

-- Refunds have no buyer_uid column; scope buyer visibility through the parent
-- payment/session ownership.
CREATE POLICY exos_order_refunds_sel ON public.exos_order_refunds FOR SELECT TO authenticated
  USING (exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance'])
         OR EXISTS (SELECT 1 FROM public.exos_order_payments p
                    WHERE p.id = payment_id AND p.buyer_uid = auth.uid()));

REVOKE ALL ON public.exos_order_payments, public.exos_order_refunds FROM anon, authenticated;
GRANT  SELECT ON public.exos_order_payments, public.exos_order_refunds TO authenticated;
