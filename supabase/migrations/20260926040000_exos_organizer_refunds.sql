-- ============================================================================
-- Migration 20260926040000 — Exos (Bridge / D4): organizer-initiated money
--                            refunds (full / partial, per ticket or order,
--                            and "refund everyone" for a cancelled event)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_refund_requests (new), exos_refund_request_items (new)
--           W: FUNCTION exos_refund_claim, exos_refund_finalize,
--              exos_refund_event_orders_svc (new, service_role only)
--           W: FUNCTION exos_refund_preview, exos_event_refund_orders
--              (new, authenticated; owner / manager / finance)
--           W: FUNCTION exos_refund_ticket_state, exos_refund_order_reserved,
--              exos_refund_orders_list (new, internal helpers, not client-callable)
--           W (inside exos_refund_finalize): exos_tickets (void), exos_ticket_tiers.sold,
--              exos_events.tickets_sold, exos_order_refunds (via exos_record_refund),
--              exos_checkout_sessions (via exos_record_refund / exos_refund_checkout)
--           R: exos_checkout_sessions, exos_order_payments, exos_order_refunds,
--              exos_org_memberships
-- Pre-reqs: 20260702123100 (payment ledger), 20260924205115 (refund ledger P0)
--
-- Until now an organizer could only VOID a ticket; the money went back through
-- the Stripe dashboard. The new exos-refund edge function lets owner / manager
-- / finance refund from the Exos UI. The money state machine lives here so the
-- edge function stays thin and every guard is in one transaction:
--
--   exos_refund_claim     locks the order (exos_checkout_sessions FOR UPDATE),
--                         checks the actor's org role, works out what is still
--                         refundable and reserves the amount as a 'claimed'
--                         request. Two concurrent claims serialize on the row
--                         lock, and the second sees the first's reservation, so
--                         they can never add up to more than was paid.
--                         Idempotent on (org_id, nonce): a retried click returns
--                         the same request (and so the same Stripe idempotency
--                         key, exos_refund_<request id>).
--   exos_refund_finalize  records Stripe's answer. 'pending' / 'succeeded' ->
--                         ledger row via exos_record_refund (same refund id the
--                         webhook will see, so a charge.refunded replay upserts
--                         the same row) + void the tickets the refund covers in
--                         full; when nothing is left refundable the whole order
--                         goes through exos_refund_checkout (voids the rest and
--                         the add-ons, like the webhook's full-refund path).
--                         'failed' / 'canceled' releases the reservation.
--                         Idempotent; the webhook calls it too (refund metadata
--                         carries the request id) so a crash between the Stripe
--                         call and finalize still reconciles.
--
-- What is refundable: the order's amount paid (exos_checkout_sessions.amount_cents,
-- the same total exos_record_refund compares against) minus every refund
-- already reserved or made: requests in claimed / pending / succeeded, plus
-- ledger refunds (pending / succeeded) that no request accounts for (dashboard
-- or auto refunds). A refund made in the Stripe dashboard therefore lowers what
-- the UI can refund.
--
-- Per-ticket share: the ticket part of the order (amount paid minus the add-on
-- lines, the same split exos_fulfill_checkout uses for price_paid) divided
-- evenly in cents over the order's tickets, the leftover cents going to the
-- first tickets (created_at, id). A ticket is voided only when the refunds
-- allocated to it reach its share. A partial refund on a ticket (a goodwill
-- discount) leaves it valid; an order-level amount not tied to tickets voids
-- nothing unless it empties the order. Checked-in ('used') tickets can be
-- refunded but are not voided.
--
-- Money is integer cents. Re-run safe. D4 authors; applying to prod is
-- operator-gated.
-- ============================================================================

-- 1. Tables --------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.exos_refund_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id       text NOT NULL REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id         uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  requested_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  scope            text NOT NULL CHECK (scope IN ('tickets', 'order', 'event_cancel')),
  amount_cents     int  NOT NULL CHECK (amount_cents > 0),
  currency         text NOT NULL DEFAULT 'usd',
  reason           text CHECK (reason IS NULL OR length(reason) <= 500),
  nonce            text NOT NULL CHECK (nonce ~ '^[A-Za-z0-9:_.-]{8,200}$'),
  status           text NOT NULL DEFAULT 'claimed'
                     CHECK (status IN ('claimed', 'pending', 'succeeded', 'failed', 'canceled')),
  payment_intent   text,
  stripe_refund_id text,
  error            text,
  voids_applied_at timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, nonce)
);
CREATE INDEX IF NOT EXISTS exos_refund_requests_session_idx ON public.exos_refund_requests (session_id);
CREATE INDEX IF NOT EXISTS exos_refund_requests_event_idx   ON public.exos_refund_requests (event_id);
CREATE INDEX IF NOT EXISTS exos_refund_requests_actor_idx   ON public.exos_refund_requests (requested_by);
CREATE UNIQUE INDEX IF NOT EXISTS exos_refund_requests_rid_uq
  ON public.exos_refund_requests (stripe_refund_id) WHERE stripe_refund_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_refund_request_items (
  request_id   uuid NOT NULL REFERENCES public.exos_refund_requests (id) ON DELETE CASCADE,
  ticket_id    uuid NOT NULL REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  amount_cents int  NOT NULL CHECK (amount_cents > 0),
  covers_full  boolean NOT NULL DEFAULT false,
  PRIMARY KEY (request_id, ticket_id)
);
CREATE INDEX IF NOT EXISTS exos_refund_request_items_ticket_idx ON public.exos_refund_request_items (ticket_id);

DROP TRIGGER IF EXISTS exos_refund_requests_touch ON public.exos_refund_requests;
CREATE TRIGGER exos_refund_requests_touch BEFORE UPDATE ON public.exos_refund_requests
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

ALTER TABLE public.exos_refund_requests      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_refund_request_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS exos_refund_requests_sel ON public.exos_refund_requests;
CREATE POLICY exos_refund_requests_sel ON public.exos_refund_requests FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

DROP POLICY IF EXISTS exos_refund_request_items_sel ON public.exos_refund_request_items;
CREATE POLICY exos_refund_request_items_sel ON public.exos_refund_request_items FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_refund_requests r
                  WHERE r.id = request_id
                    AND exos_has_org_role(r.org_id, ARRAY['owner','manager','finance'])));

REVOKE ALL ON public.exos_refund_requests, public.exos_refund_request_items FROM PUBLIC, anon, authenticated;
GRANT  SELECT ON public.exos_refund_requests, public.exos_refund_request_items TO authenticated;
GRANT  ALL    ON public.exos_refund_requests, public.exos_refund_request_items TO service_role;

-- 2. Internal helpers (not client-callable) ------------------------------------

-- Per ticket on the order: its share of the ticket part of the order, and the
-- refunds already allocated to it (claimed / pending / succeeded requests).
CREATE OR REPLACE FUNCTION public.exos_refund_ticket_state(p_session_id text)
RETURNS TABLE (ticket_id uuid, ticket_status text, share_cents int, allocated_cents int)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  WITH s AS (
    SELECT cs.amount_cents,
           greatest(cs.amount_cents - coalesce((
             SELECT sum(coalesce((a->>'quantity')::int, 0) * coalesce((a->>'unit_price_cents')::int, 0))
               FROM jsonb_array_elements(CASE WHEN jsonb_typeof(cs.addons) = 'array' THEN cs.addons ELSE '[]'::jsonb END) a
           ), 0), 0)::int AS pool
      FROM public.exos_checkout_sessions cs WHERE cs.session_id = p_session_id
  ), t AS (
    SELECT tk.id, tk.status,
           row_number() OVER (ORDER BY tk.created_at, tk.id) AS rn,
           count(*)     OVER ()                              AS n
      FROM public.exos_tickets tk WHERE tk.order_ref = p_session_id
  ), alloc AS (
    SELECT i.ticket_id, sum(i.amount_cents)::int AS amt
      FROM public.exos_refund_request_items i
      JOIN public.exos_refund_requests r ON r.id = i.request_id
     WHERE r.session_id = p_session_id AND r.status IN ('claimed', 'pending', 'succeeded')
     GROUP BY i.ticket_id
  )
  SELECT t.id, t.status,
         (s.pool / t.n + CASE WHEN t.rn <= s.pool % t.n THEN 1 ELSE 0 END)::int,
         coalesce(alloc.amt, 0)
    FROM t CROSS JOIN s LEFT JOIN alloc ON alloc.ticket_id = t.id
   ORDER BY t.rn;
$$;
REVOKE ALL ON FUNCTION public.exos_refund_ticket_state(text) FROM PUBLIC, anon, authenticated;

-- Everything already refunded or reserved against the order.
CREATE OR REPLACE FUNCTION public.exos_refund_order_reserved(p_session_id text)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT (coalesce((SELECT sum(r.amount_cents) FROM public.exos_refund_requests r
                     WHERE r.session_id = p_session_id
                       AND r.status IN ('claimed', 'pending', 'succeeded')), 0)
        + coalesce((SELECT sum(o.amount_cents) FROM public.exos_order_refunds o
                     WHERE o.session_id = p_session_id
                       AND o.status IN ('pending', 'succeeded')
                       AND NOT EXISTS (SELECT 1 FROM public.exos_refund_requests r
                                        WHERE r.stripe_refund_id = o.refund_id)), 0))::int;
$$;
REVOKE ALL ON FUNCTION public.exos_refund_order_reserved(text) FROM PUBLIC, anon, authenticated;

-- 3. Claim (service_role; the edge function passes the verified user id) ------

CREATE OR REPLACE FUNCTION public.exos_refund_claim(
  p_actor        uuid,
  p_session_id   text,
  p_nonce        text,
  p_items        jsonb   DEFAULT NULL,   -- [{ "ticket_id": uuid, "amount_cents": int? }]; omitted amount = what's left on it
  p_amount_cents int     DEFAULT NULL,   -- order-level amount not tied to tickets
  p_whole_order  boolean DEFAULT false,  -- everything still refundable
  p_reason       text    DEFAULT NULL,
  p_scope        text    DEFAULT NULL    -- 'event_cancel' from the cancel flow; else derived
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s          public.exos_checkout_sessions%ROWTYPE;
  v_req      public.exos_refund_requests%ROWTYPE;
  v_pi       text;
  v_left     int;
  v_total    int := 0;
  v_scope    text;
  v_id       uuid;
  v_it       jsonb;
  v_tid      uuid;
  v_amt      int;
  st         record;
  v_plan     jsonb := '[]'::jsonb;
  v_seen     uuid[] := '{}';
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_refund_claim: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'exos_refund_claim: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_nonce IS NULL OR p_nonce !~ '^[A-Za-z0-9:_.-]{8,200}$' THEN
    RAISE EXCEPTION 'exos_refund_claim: a request nonce is required' USING ERRCODE = '22023';
  END IF;

  -- The order row lock serializes every claim / finalize on this order.
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_refund_claim: order not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                  WHERE m.org_id = s.org_id AND m.user_id = p_actor
                    AND m.disabled IS NOT TRUE
                    AND m.role IN ('owner', 'manager', 'finance')) THEN
    RAISE EXCEPTION 'exos_refund_claim: not authorized' USING ERRCODE = '42501';
  END IF;

  -- Same click again (retry, double submit): hand back the same request.
  SELECT * INTO v_req FROM public.exos_refund_requests WHERE org_id = s.org_id AND nonce = p_nonce;
  IF FOUND THEN
    IF v_req.session_id <> p_session_id THEN
      RAISE EXCEPTION 'exos_refund_claim: nonce already used for another order' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object(
      'request_id', v_req.id, 'session_id', v_req.session_id, 'amount_cents', v_req.amount_cents, 'currency', v_req.currency,
      'payment_intent', v_req.payment_intent, 'idempotency_key', 'exos_refund_' || v_req.id,
      'status', v_req.status, 'stripe_refund_id', v_req.stripe_refund_id,
      'scope', v_req.scope, 'existing', true);
  END IF;

  IF s.status NOT IN ('fulfilled', 'partially_refunded', 'refunded') THEN
    RAISE EXCEPTION 'exos_refund_claim: order is % and has nothing to refund', s.status USING ERRCODE = '22023';
  END IF;
  SELECT p.payment_intent INTO v_pi FROM public.exos_order_payments p
   WHERE p.session_id = p_session_id AND p.status = 'succeeded' AND p.payment_intent IS NOT NULL
   ORDER BY p.amount_cents DESC LIMIT 1;
  v_pi := coalesce(v_pi, s.payment_intent);
  IF v_pi IS NULL THEN
    RAISE EXCEPTION 'exos_refund_claim: no card payment on file for this order' USING ERRCODE = '22023';
  END IF;

  v_left := greatest(s.amount_cents - public.exos_refund_order_reserved(p_session_id), 0);
  IF v_left <= 0 THEN
    RAISE EXCEPTION 'exos_refund_claim: nothing left to refund on this order' USING ERRCODE = '22023';
  END IF;

  IF coalesce(p_whole_order, false) THEN
    v_scope := 'order';
    v_total := v_left;
    -- Allocate what's left to each ticket's remaining share, in order.
    v_amt := v_left;
    FOR st IN SELECT * FROM public.exos_refund_ticket_state(p_session_id) LOOP
      EXIT WHEN v_amt <= 0;
      IF st.share_cents - st.allocated_cents > 0 THEN
        v_plan := v_plan || jsonb_build_object(
          'ticket_id', st.ticket_id,
          'amount_cents', least(st.share_cents - st.allocated_cents, v_amt),
          'covers_full', least(st.share_cents - st.allocated_cents, v_amt) = st.share_cents - st.allocated_cents);
        v_amt := v_amt - least(st.share_cents - st.allocated_cents, v_amt);
      END IF;
    END LOOP;
  ELSIF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' AND jsonb_array_length(p_items) > 0 THEN
    v_scope := 'tickets';
    IF jsonb_array_length(p_items) > 100 THEN
      RAISE EXCEPTION 'exos_refund_claim: at most 100 tickets per refund' USING ERRCODE = '22023';
    END IF;
    FOR v_it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      BEGIN
        v_tid := (v_it->>'ticket_id')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'exos_refund_claim: bad ticket id' USING ERRCODE = '22023';
      END;
      IF v_tid = ANY (v_seen) THEN
        RAISE EXCEPTION 'exos_refund_claim: ticket listed twice' USING ERRCODE = '22023';
      END IF;
      v_seen := v_seen || v_tid;
      SELECT * INTO st FROM public.exos_refund_ticket_state(p_session_id) x WHERE x.ticket_id = v_tid;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'exos_refund_claim: ticket is not on this order' USING ERRCODE = '22023';
      END IF;
      IF v_it ? 'amount_cents' AND v_it->'amount_cents' <> 'null'::jsonb THEN
        IF jsonb_typeof(v_it->'amount_cents') <> 'number' OR (v_it->>'amount_cents')::numeric <> floor((v_it->>'amount_cents')::numeric) THEN
          RAISE EXCEPTION 'exos_refund_claim: amount must be whole cents' USING ERRCODE = '22023';
        END IF;
        v_amt := (v_it->>'amount_cents')::int;
      ELSE
        v_amt := st.share_cents - st.allocated_cents;
      END IF;
      IF v_amt <= 0 THEN
        RAISE EXCEPTION 'exos_refund_claim: nothing left to refund on ticket %', left(v_tid::text, 8) USING ERRCODE = '22023';
      END IF;
      IF v_amt > st.share_cents - st.allocated_cents THEN
        RAISE EXCEPTION 'exos_refund_claim: % cents is more than the % left on ticket %',
          v_amt, st.share_cents - st.allocated_cents, left(v_tid::text, 8) USING ERRCODE = '22023';
      END IF;
      v_total := v_total + v_amt;
      v_plan := v_plan || jsonb_build_object('ticket_id', v_tid, 'amount_cents', v_amt,
                                             'covers_full', v_amt = st.share_cents - st.allocated_cents);
    END LOOP;
  ELSIF p_amount_cents IS NOT NULL THEN
    v_scope := 'order';
    v_total := p_amount_cents;
  ELSE
    RAISE EXCEPTION 'exos_refund_claim: say what to refund (tickets, an amount, or the whole order)' USING ERRCODE = '22023';
  END IF;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'exos_refund_claim: refund amount must be positive' USING ERRCODE = '22023';
  END IF;
  IF v_total > v_left THEN
    RAISE EXCEPTION 'exos_refund_claim: % cents is more than the % cents left to refund', v_total, v_left
      USING ERRCODE = '22023';
  END IF;
  IF p_scope = 'event_cancel' THEN v_scope := 'event_cancel'; END IF;

  INSERT INTO public.exos_refund_requests (
    session_id, org_id, event_id, requested_by, scope, amount_cents, currency,
    reason, nonce, status, payment_intent
  ) VALUES (
    p_session_id, s.org_id, s.event_id, p_actor, v_scope, v_total, lower(coalesce(s.currency, 'usd')),
    left(nullif(btrim(coalesce(p_reason, '')), ''), 500), p_nonce, 'claimed', v_pi
  ) RETURNING id INTO v_id;

  INSERT INTO public.exos_refund_request_items (request_id, ticket_id, amount_cents, covers_full)
  SELECT v_id, (e->>'ticket_id')::uuid, (e->>'amount_cents')::int, (e->>'covers_full')::boolean
    FROM jsonb_array_elements(v_plan) e
   WHERE (e->>'amount_cents')::int > 0;

  RETURN jsonb_build_object(
    'request_id', v_id, 'session_id', p_session_id, 'amount_cents', v_total, 'currency', lower(coalesce(s.currency, 'usd')),
    'payment_intent', v_pi, 'idempotency_key', 'exos_refund_' || v_id,
    'status', 'claimed', 'stripe_refund_id', NULL, 'scope', v_scope, 'existing', false);
END $$;
REVOKE ALL ON FUNCTION public.exos_refund_claim(uuid, text, text, jsonb, int, boolean, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_refund_claim(uuid, text, text, jsonb, int, boolean, text, text)
  TO service_role;

-- 4. Finalize (service_role; exos-refund after Stripe answers, and stripe-webhook) --

CREATE OR REPLACE FUNCTION public.exos_refund_finalize(
  p_request_id       uuid,
  p_stripe_refund_id text,
  p_status           text,               -- Stripe refund status, or 'failed' when Stripe refused
  p_error            text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_req    public.exos_refund_requests%ROWTYPE;
  v_sess   text;
  s        public.exos_checkout_sessions%ROWTYPE;
  v_status text;
  v_voided int := 0;
  v_left   int;
  r        record;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_refund_finalize: service role only' USING ERRCODE = '42501';
  END IF;
  v_status := CASE WHEN p_status IN ('pending', 'succeeded', 'failed', 'canceled') THEN p_status
                   WHEN p_status = 'requires_action' THEN 'pending'
                   ELSE 'pending' END;

  -- Lock order first, then the request (same order as exos_refund_claim).
  SELECT session_id INTO v_sess FROM public.exos_refund_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_refund_finalize: unknown request %', p_request_id USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = v_sess FOR UPDATE;
  SELECT * INTO v_req FROM public.exos_refund_requests WHERE id = p_request_id FOR UPDATE;

  IF v_req.stripe_refund_id IS NOT NULL AND p_stripe_refund_id IS NOT NULL
     AND v_req.stripe_refund_id <> p_stripe_refund_id THEN
    RAISE EXCEPTION 'exos_refund_finalize: request % is already tied to refund %', p_request_id, v_req.stripe_refund_id;
  END IF;

  -- Never move backwards: a final state stays final (a late 'pending' replay
  -- after 'succeeded' is a no-op); only pending -> succeeded/failed moves on.
  IF v_req.status IN ('succeeded', 'failed', 'canceled')
     OR (v_req.status = 'pending' AND v_status = 'pending') THEN
    RETURN jsonb_build_object('request_id', v_req.id, 'status', v_req.status, 'voided', 0, 'changed', false);
  END IF;

  IF v_status IN ('failed', 'canceled') THEN
    UPDATE public.exos_refund_requests
       SET status = v_status,
           stripe_refund_id = coalesce(stripe_refund_id, p_stripe_refund_id),
           error = left(coalesce(p_error, error), 500)
     WHERE id = p_request_id;
    IF coalesce(v_req.stripe_refund_id, p_stripe_refund_id) IS NOT NULL THEN
      PERFORM public.exos_record_refund(v_req.session_id, coalesce(v_req.stripe_refund_id, p_stripe_refund_id),
        v_req.amount_cents, v_status, v_req.payment_intent, coalesce(v_req.reason, 'organizer refund'),
        v_req.currency, NULL, jsonb_build_object('exos_refund_request_id', v_req.id));
    END IF;
    RETURN jsonb_build_object('request_id', v_req.id, 'status', v_status, 'voided', 0, 'changed', true,
      'note', CASE WHEN v_req.voids_applied_at IS NOT NULL THEN 'tickets were already voided' END);
  END IF;

  IF p_stripe_refund_id IS NULL AND v_req.stripe_refund_id IS NULL THEN
    RAISE EXCEPTION 'exos_refund_finalize: a Stripe refund id is required' USING ERRCODE = '22023';
  END IF;

  UPDATE public.exos_refund_requests
     SET status = v_status, stripe_refund_id = coalesce(stripe_refund_id, p_stripe_refund_id), error = NULL
   WHERE id = p_request_id;

  -- Ledger: the same refund id the webhook records, so neither doubles it.
  PERFORM public.exos_record_refund(v_req.session_id, coalesce(v_req.stripe_refund_id, p_stripe_refund_id),
    v_req.amount_cents, v_status, v_req.payment_intent, coalesce(v_req.reason, 'organizer refund'),
    v_req.currency, NULL, jsonb_build_object('exos_refund_request_id', v_req.id));

  -- Void once, when Stripe has accepted the refund (pending or succeeded).
  IF v_req.voids_applied_at IS NULL THEN
    FOR r IN
      UPDATE public.exos_tickets t
         SET status = 'voided', voided_at = now(), voided_by = v_req.requested_by,
             voided_reason = left('refunded: ' || coalesce(v_req.reason, 'organizer refund'), 500)
       WHERE t.status = 'active'
         AND t.id IN (SELECT st.ticket_id FROM public.exos_refund_ticket_state(v_req.session_id) st
                       WHERE st.allocated_cents >= st.share_cents
                         AND st.ticket_id IN (SELECT i.ticket_id FROM public.exos_refund_request_items i
                                               WHERE i.request_id = v_req.id))
      RETURNING t.tier_id
    LOOP
      v_voided := v_voided + 1;
      IF r.tier_id IS NOT NULL THEN
        UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = r.tier_id;
      END IF;
    END LOOP;
    IF v_voided > 0 THEN
      UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_voided) WHERE id = s.event_id;
    END IF;

    -- Nothing left to refund: the whole order is refunded (voids the rest + add-ons).
    v_left := s.amount_cents - public.exos_refund_order_reserved(v_req.session_id);
    IF v_left <= 0 THEN
      v_voided := v_voided + public.exos_refund_checkout(v_req.session_id,
        'refunded: ' || coalesce(v_req.reason, 'organizer refund'));
    END IF;

    UPDATE public.exos_refund_requests SET voids_applied_at = now() WHERE id = p_request_id;
  END IF;

  RETURN jsonb_build_object('request_id', v_req.id, 'status', v_status, 'voided', v_voided, 'changed', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_refund_finalize(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_refund_finalize(uuid, text, text, text) TO service_role;

-- 5. Orders on an event with money left to refund -------------------------------

-- Internal: paid orders on an event with their refund totals. p_order 'cursor'
-- pages by session_id after p_after (the cancel flow); 'recent' is newest first.
CREATE OR REPLACE FUNCTION public.exos_refund_orders_list(
  p_event_id uuid, p_after text, p_limit int, p_only_refundable boolean, p_order text)
RETURNS TABLE (session_id text, buyer_email text, created_at timestamptz, status text,
               amount_cents int, refunded_cents int, refundable_cents int,
               tickets int, active_tickets int, open_requests int, currency text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT x.* FROM (
    SELECT cs.session_id, cs.buyer_email, cs.created_at, cs.status, cs.amount_cents,
           public.exos_refund_order_reserved(cs.session_id) AS refunded_cents,
           CASE WHEN cs.payment_intent IS NULL
                     AND NOT EXISTS (SELECT 1 FROM public.exos_order_payments p
                                      WHERE p.session_id = cs.session_id AND p.status = 'succeeded'
                                        AND p.payment_intent IS NOT NULL)
                THEN 0
                ELSE greatest(cs.amount_cents - public.exos_refund_order_reserved(cs.session_id), 0) END AS refundable_cents,
           (SELECT count(*)::int FROM public.exos_tickets t WHERE t.order_ref = cs.session_id) AS tickets,
           (SELECT count(*)::int FROM public.exos_tickets t WHERE t.order_ref = cs.session_id AND t.status = 'active') AS active_tickets,
           (SELECT count(*)::int FROM public.exos_refund_requests r
             WHERE r.session_id = cs.session_id AND r.status IN ('claimed', 'pending')) AS open_requests,
           cs.currency
      FROM public.exos_checkout_sessions cs
     WHERE cs.event_id = p_event_id
       AND cs.status IN ('fulfilled', 'partially_refunded', 'refunded')
       AND cs.amount_cents > 0
       AND (p_after IS NULL OR cs.session_id > p_after)
  ) x
  WHERE NOT coalesce(p_only_refundable, false) OR x.refundable_cents > 0
  ORDER BY CASE WHEN p_order = 'recent' THEN NULL ELSE x.session_id END,
           x.created_at DESC
  LIMIT greatest(1, least(coalesce(p_limit, 200), 500));
$$;
REVOKE ALL ON FUNCTION public.exos_refund_orders_list(uuid, text, int, boolean, text) FROM PUBLIC, anon, authenticated;

-- Service-role variant for the cancel flow (actor checked here). Pages by
-- session_id: pass the last session_id returned as p_after.
CREATE OR REPLACE FUNCTION public.exos_refund_event_orders_svc(
  p_actor uuid, p_event_id uuid, p_after text DEFAULT NULL, p_limit int DEFAULT 25)
RETURNS TABLE (session_id text, refundable_cents int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_org uuid;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'exos_refund_event_orders_svc: service role only' USING ERRCODE = '42501';
  END IF;
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL OR p_actor IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = v_org AND m.user_id = p_actor AND m.disabled IS NOT TRUE
          AND m.role IN ('owner', 'manager', 'finance')) THEN
    RAISE EXCEPTION 'exos_refund_event_orders_svc: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT o.session_id, o.refundable_cents
      FROM public.exos_refund_orders_list(p_event_id, p_after, least(coalesce(p_limit, 25), 100), true, 'cursor') o;
END $$;
REVOKE ALL ON FUNCTION public.exos_refund_event_orders_svc(uuid, uuid, text, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_refund_event_orders_svc(uuid, uuid, text, int) TO service_role;

-- 6. UI reads (authenticated; owner / manager / finance) ------------------------

-- Newest orders first (up to 500), for the refund panel.
CREATE OR REPLACE FUNCTION public.exos_event_refund_orders(p_event_id uuid)
RETURNS TABLE (session_id text, buyer_email text, created_at timestamptz, status text,
               amount_cents int, refunded_cents int, refundable_cents int,
               tickets int, active_tickets int, open_requests int, currency text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_refund_orders: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL OR NOT exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_event_refund_orders: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public.exos_refund_orders_list(p_event_id, NULL, 500, false, 'recent');
END $$;
REVOKE ALL ON FUNCTION public.exos_event_refund_orders(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_refund_orders(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_refund_preview(p_session_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s        public.exos_checkout_sessions%ROWTYPE;
  v_res    int;
  v_left   int;
  v_has_pi boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_refund_preview: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND OR NOT exos_has_org_role(s.org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_refund_preview: not authorized' USING ERRCODE = '42501';
  END IF;
  v_has_pi := s.payment_intent IS NOT NULL OR EXISTS (
    SELECT 1 FROM public.exos_order_payments p
     WHERE p.session_id = p_session_id AND p.status = 'succeeded' AND p.payment_intent IS NOT NULL);
  v_res  := public.exos_refund_order_reserved(p_session_id);
  v_left := CASE WHEN v_has_pi AND s.status IN ('fulfilled', 'partially_refunded', 'refunded')
                 THEN greatest(s.amount_cents - v_res, 0) ELSE 0 END;
  RETURN jsonb_build_object(
    'session_id', s.session_id,
    'status', s.status,
    'currency', s.currency,
    'amount_cents', s.amount_cents,
    'refunded_cents', v_res,
    'refundable_cents', v_left,
    'has_payment', v_has_pi,
    'tickets', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'ticket_id', st.ticket_id, 'status', st.ticket_status,
               'share_cents', st.share_cents, 'refunded_cents', st.allocated_cents,
               'refundable_cents', CASE WHEN v_left > 0 THEN least(greatest(st.share_cents - st.allocated_cents, 0), v_left) ELSE 0 END,
               'tier_name', t.tier_name, 'attendee_name', t.attendee_name))
        FROM public.exos_refund_ticket_state(p_session_id) st
        JOIN public.exos_tickets t ON t.id = st.ticket_id), '[]'::jsonb),
    'requests', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', r.id, 'amount_cents', r.amount_cents, 'status', r.status, 'scope', r.scope,
               'reason', r.reason, 'created_at', r.created_at, 'error', r.error) ORDER BY r.created_at)
        FROM public.exos_refund_requests r WHERE r.session_id = p_session_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_refund_preview(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_refund_preview(text) TO authenticated, service_role;
