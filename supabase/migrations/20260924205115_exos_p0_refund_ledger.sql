-- ============================================================================
-- Migration 20260924205115 — Exos (Bridge / D4): P0 — refunds can't leave
-- Already applied to prod via Supabase MCP on 2026-09-24 (operator-approved, Exos P0 + all-in; Terminal-2 #1003).
--                            valid tickets behind
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_refund_checkout (replaced), FUNCTION exos_record_refund (replaced)
--           R: exos_checkout_sessions, exos_order_payments, exos_order_refunds, exos_tickets
-- Pre-reqs: 20260616190000 (exos_refund_checkout), 20260702123100 (payment ledger)
--
-- P0 (audit 2026-09-24, HIGH). A partial refund followed by the rest could
-- refund the buyer in full and leave every ticket valid:
--   * stripe-webhook's charge.refunded handler fell back to one NULL-refund-id
--     row carrying the CUMULATIVE charge.amount_refunded whenever the event
--     had no embedded refunds list — which, on API 2022-11-15+, is always.
--     NULL ids never dedupe, so $20 then $15 on a $50 order summed to 20+35 =
--     55 >= 50 and exos_record_refund flipped the session to 'refunded'.
--   * exos_refund_checkout then returned early on status = 'refunded', so the
--     real full refund voided nothing.
-- Fix, defence in depth (the webhook now also records each refund by id):
--   * exos_record_refund refuses a NULL refund id — every Stripe refund has one.
--   * exos_refund_checkout is idempotent instead of early-returning: it always
--     voids whatever is still active on the order, so a session already marked
--     'refunded' by an earlier miscount still gets its tickets voided.
--
-- Idempotent: CREATE OR REPLACE only. Signatures and grants unchanged.
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_refund_checkout(
  p_session_id text,
  p_reason     text DEFAULT 'refunded'
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s     public.exos_checkout_sessions%ROWTYPE;
  v_n   int := 0;
  r     record;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_refund_checkout: unknown session %', p_session_id;
  END IF;

  -- No early return on status = 'refunded': voiding only touches rows that are
  -- still active, so a replay is a no-op and a mis-marked session still voids.
  FOR r IN
    UPDATE public.exos_tickets
       SET status = 'voided', voided_at = now(),
           voided_reason = left(coalesce(p_reason, 'refunded'), 500)
     WHERE order_ref = p_session_id AND status = 'active'
    RETURNING tier_id
  LOOP
    v_n := v_n + 1;
    IF r.tier_id IS NOT NULL THEN
      UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = r.tier_id;
    END IF;
  END LOOP;

  IF v_n > 0 THEN
    UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_n) WHERE id = s.event_id;
  END IF;

  FOR r IN
    UPDATE public.exos_order_addons
       SET status = 'refunded'
     WHERE order_ref = p_session_id AND status = 'active'
    RETURNING addon_id, quantity
  LOOP
    IF r.addon_id IS NOT NULL THEN
      UPDATE public.exos_event_addons SET sold = greatest(0, sold - r.quantity) WHERE id = r.addon_id;
    END IF;
  END LOOP;

  IF s.status <> 'refunded' THEN
    UPDATE public.exos_checkout_sessions
       SET status = 'refunded', failure_reason = left(coalesce(p_reason, 'refunded'), 500)
     WHERE session_id = p_session_id;
  END IF;

  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_refund_checkout(text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_refund_checkout(text, text) TO service_role;

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
  -- A NULL id can't be deduplicated, so a cumulative amount recorded under it
  -- double-counts on every retry or later partial refund.
  IF p_refund_id IS NULL OR btrim(p_refund_id) = '' THEN
    RAISE EXCEPTION 'exos_record_refund: refund id is required';
  END IF;

  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_record_refund: unknown session %', p_session_id;
  END IF;

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
