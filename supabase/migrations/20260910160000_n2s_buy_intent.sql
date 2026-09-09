-- ============================================================================
-- Migration 20260910160000 — buy intents: a manual, verify-gated buy request
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_buy_intent (CREATE TABLE), n2s_buy_intent_create(),
--           n2s_buy_intent_cancel()
-- Pre-reqs: 20260910150000
--
-- READ-ONLY upstream: NOTHING here calls any upstream API. It records an
-- INTENT and builds a reviewable payload. RULE 2 is untouched and every
-- *_client.py stays GET-only.
--
-- Operator direction 2026-09-09: "build. buy side for Evo and go tickets but,
-- don't automate. we gonna push the sg, Evo and go tix data to the CRM in real
-- time as we match and allow for that system to trigger buy option manually."
--
-- ── ⚠ WHAT THIS DELIBERATELY STOPS SHORT OF ───────────────────────────────
-- This is the buy side up to, and NOT including, the network call. An intent
-- is a durable, audited record that a human asked to buy a specific listing at
-- a specific price, plus the exact request body that would be sent. Nothing
-- sends it.
--
-- That is not timidity, it is the only correct stopping point today:
--
--   1. GOTICKETS HAS NO PURCHASE API AT ALL. gotickets_client.py is the Broker
--      SALES api (sc.gotickets.com, GET /rest/sales) — sell-side. The buy link
--      we emit is pro.gotickets.com, a WEB STOREFRONT. There is no endpoint to
--      POST an order to, so a GoTickets intent is, correctly, a link plus a
--      record that someone is acting on it.
--   2. AN EVO ORDER NEEDS FACTS WE DO NOT HAVE. Orders/Create requires a
--      client_id, a payment method (Braintree token or `offline`), and a
--      delivery method + address_id. None exist in this database, and none can
--      be invented — see docs/evo_buy_side.md §1. The payload below is built
--      with those fields NULL and flagged, so it is visibly incomplete rather
--      than falsely ready.
--   3. THE DELIVERY LEG IS UNRESOLVED. The vendor flow ships to a customer of
--      OURS; an N2S cover must reach the ORIGINAL marketplace's buyer on that
--      marketplace's terms (docs/evo_buy_side.md §3). Sending an order before
--      that is answered buys tickets with nowhere to go.
--
-- ⚠ AN INTENT IS REFUSED UNLESS THE COVER VERIFIES BUYABLE. n2s_cover_verify()
-- runs at creation time and a `gone` or `order_closed` cover cannot become an
-- intent at all. The verdict is STORED on the row, so the record says what was
-- true when the human asked — not what is true whenever someone reads it back.
-- `stale_data` is refused too: "we cannot tell" is not consent to spend money.
--
-- ⚠ THE PRICE IS PINNED AT REQUEST TIME. quoted_ea is what the human agreed
-- to. If the listing later moves, that is a NEW decision, not a silent update
-- of an existing intent. Nothing in here rewrites a price.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.n2s_buy_intent (
  intent_id      bigserial PRIMARY KEY,
  n2s_id         bigint NOT NULL,
  order_number   text   NOT NULL,
  s4k_source     text,
  -- the cover, frozen as it was when the human asked
  sub_source     text   NOT NULL,
  sub_listing_id text   NOT NULL,
  tevo_event_id  bigint,
  sub_section    text,
  sub_row        text,
  sub_qty        integer,
  quoted_ea      numeric,
  quoted_total   numeric,
  cover_cost     numeric,
  buy_url        text,
  -- what verification said AT REQUEST TIME
  verify_verdict text,
  verify_delta   numeric,
  status         text NOT NULL DEFAULT 'requested'
    CHECK (status IN ('requested','placed','failed','cancelled')),
  requested_by   text,
  requested_at   timestamptz NOT NULL DEFAULT now(),
  -- the reviewable request body. NEVER sent by anything in this migration.
  payload        jsonb,
  payload_ready  boolean NOT NULL DEFAULT false,
  payload_gaps   text[],
  placed_at      timestamptz,
  external_order_id text,
  error_msg      text,
  notes          text
);

CREATE INDEX IF NOT EXISTS n2s_buy_intent_open_idx
  ON public.n2s_buy_intent (requested_at DESC) WHERE status = 'requested';
CREATE INDEX IF NOT EXISTS n2s_buy_intent_n2s_idx ON public.n2s_buy_intent (n2s_id);

-- One OPEN intent per order. Two people acting on the same failed order would
-- otherwise buy two covers for one obligation — the same double-spend the FIFO
-- allocator prevents between orders, here between people.
CREATE UNIQUE INDEX IF NOT EXISTS n2s_buy_intent_one_open_per_order
  ON public.n2s_buy_intent (n2s_id) WHERE status = 'requested';

ALTER TABLE public.n2s_buy_intent ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.n2s_buy_intent IS
  'A human asked to buy a specific cover at a specific price. Records the '
  'frozen cover, the verification verdict AT REQUEST TIME, and the reviewable '
  'order payload. NOTHING SENDS IT — no upstream call is made from anywhere in '
  'this pipeline. GoTickets has no purchase API (the link is a web storefront); '
  'an EVO order still needs client_id, payment and delivery, listed in '
  'payload_gaps. See docs/evo_buy_side.md.';

CREATE OR REPLACE FUNCTION public.n2s_buy_intent_create(
  p_n2s_id       bigint,
  p_requested_by text DEFAULT NULL,
  p_notes        text DEFAULT NULL
)
RETURNS TABLE(intent_id bigint, status text, verdict text,
              payload_ready boolean, payload_gaps text[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  c  RECORD;
  v  RECORD;
  v_gaps text[] := '{}';
  v_payload jsonb;
  v_ready boolean := false;
  v_id bigint;
BEGIN
  SELECT * INTO c FROM public.n2s_cover_queue WHERE n2s_id = p_n2s_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'n2s_buy_intent_create: no queued cover for n2s_id %', p_n2s_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Verify FIRST. A gone / order_closed / stale_data cover cannot become an
  -- intent: "we cannot tell" is not consent to spend money.
  SELECT * INTO v FROM public.n2s_cover_verify(ARRAY[p_n2s_id]) LIMIT 1;
  IF v IS NULL OR NOT COALESCE(v.buyable, false) THEN
    RAISE EXCEPTION 'n2s_buy_intent_create: cover for n2s_id % is not buyable (%)',
      p_n2s_id, COALESCE(v.verdict, 'no verdict') USING ERRCODE = 'check_violation';
  END IF;

  -- Build the reviewable body. Fields we genuinely do not hold stay NULL and
  -- are NAMED in payload_gaps, so the record is visibly incomplete rather than
  -- looking ready to send.
  IF c.sub_source = 'tevo' THEN
    IF NOT EXISTS (SELECT 1 FROM public.n2s_items i
                    WHERE i.n2s_id = p_n2s_id AND i.tevo_event_id IS NOT NULL) THEN
      v_gaps := v_gaps || 'tevo_event_id';
    END IF;
    v_gaps := v_gaps || ARRAY['client_id','payment_method','delivery_method','address_id'];
    v_payload := jsonb_build_object(
      'endpoint',      'POST /orders',
      'type',          'customer',
      'ticket_group_id', c.sub_listing_id,
      'quantity',      c.sub_qty,
      'price_per_ticket', c.quoted_ea,
      -- deliberately null: see payload_gaps and docs/evo_buy_side.md §1
      'client_id',     NULL,
      'payment_type',  NULL,
      'delivery',      NULL,
      'address_id',    NULL);
  ELSIF c.sub_source = 'gotickets' THEN
    -- No purchase API exists. The storefront link IS the buy path.
    v_gaps := ARRAY['no_purchase_api__use_buy_url'];
    v_payload := jsonb_build_object(
      'endpoint', 'WEB',
      'buy_url',  c.buy_url,
      'section',  c.sub_section,
      'row',      c.sub_row,
      'quantity', c.sub_qty);
  ELSE
    v_gaps := ARRAY['no_purchase_integration_for_' || c.sub_source];
    v_payload := jsonb_build_object('endpoint', 'NONE', 'source', c.sub_source);
  END IF;

  v_ready := (cardinality(v_gaps) = 0);

  INSERT INTO public.n2s_buy_intent (
    n2s_id, order_number, s4k_source, sub_source, sub_listing_id, tevo_event_id,
    sub_section, sub_row, sub_qty, quoted_ea, quoted_total, cover_cost, buy_url,
    verify_verdict, verify_delta, requested_by, payload, payload_ready,
    payload_gaps, notes)
  VALUES (
    c.n2s_id, c.order_number, c.s4k_source, c.sub_source, c.sub_listing_id,
    c.tevo_event_id, c.sub_section, c.sub_row, c.sub_qty, c.sub_ea,
    c.sub_total, c.cover_cost, c.buy_url,
    v.verdict, v.price_delta_ea, p_requested_by, v_payload, v_ready,
    v_gaps, p_notes)
  RETURNING n2s_buy_intent.intent_id INTO v_id;

  RETURN QUERY SELECT v_id, 'requested'::text, v.verdict, v_ready, v_gaps;
END $function$;

CREATE OR REPLACE FUNCTION public.n2s_buy_intent_cancel(
  p_intent_id bigint, p_by text DEFAULT NULL, p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
  WITH u AS (
    UPDATE public.n2s_buy_intent
       SET status = 'cancelled',
           error_msg = COALESCE(p_reason, error_msg),
           notes = COALESCE(notes || ' | ', '') || 'cancelled by ' || COALESCE(p_by, 'unknown')
     WHERE intent_id = p_intent_id AND status = 'requested'
    RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM u);
$$;

REVOKE ALL ON FUNCTION public.n2s_buy_intent_create(bigint,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.n2s_buy_intent_cancel(bigint,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_buy_intent_create(bigint,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.n2s_buy_intent_cancel(bigint,text,text) TO authenticated, service_role;
REVOKE ALL ON public.n2s_buy_intent FROM PUBLIC, anon;
GRANT SELECT ON public.n2s_buy_intent TO authenticated, service_role;
