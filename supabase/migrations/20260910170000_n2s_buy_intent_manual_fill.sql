-- ============================================================================
-- Migration 20260910170000 — an intent is a FILL SHEET, not a blocked payload
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_buy_intent (ADD COLUMN operator_fills), n2s_buy_intent_create()
-- Pre-reqs: 20260910160000
--
-- READ-ONLY upstream: nothing here calls any upstream API. RULE 2 untouched.
--
-- Operator direction 2026-09-09: "no it will flow to us and then we will fill
-- manually for both go and evo."
--
-- ── WHAT CHANGED AND WHY ──────────────────────────────────────────────────
-- 20260910160000 lumped every absent field into one `payload_gaps` array, so
-- an intent read as BLOCKED. That framing was wrong for how this is actually
-- run: the buy is placed BY HAND in the vendor console. A payment token or a
-- delivery method is not something we are missing — it is something the human
-- supplies at checkout, and it was never going to arrive from our side.
--
-- So the absent fields are split by WHO OWES THEM:
--
--   payload_gaps    — data WE hold-or-should-hold and could not produce (e.g.
--                     an unmapped gt_event_id). A real defect on our side.
--                     Empty = we did our part; that is what payload_ready now
--                     means, and it no longer means "sendable by machine".
--   operator_fills  — fields the human enters in the vendor console. Expected,
--                     not broken. A non-empty list is the normal case.
--
-- ⚠ THE DISTINCTION IS THE POINT. Collapsing them again makes every intent look
-- defective, which trains people to ignore the flag — and then a REAL gap (an
-- unmapped event, a listing we cannot address) reads the same as "type in your
-- card number" and gets ignored with it.
--
-- ⚠ `recipient` STAYS ON THE HUMAN'S LIST PERMANENTLY. It needs the original
-- marketplace buyer's name and address, which we deliberately do not ingest
-- (n2s_items strips customer_name/customer_email at the door, in the column
-- list AND out of `raw`). That is a privacy decision, not a missing feature —
-- do not "fix" it by starting to store buyer PII.
--
-- ⚠ expectedTotal IS ON THE HUMAN'S LIST, NOT OURS. It is GoTickets' API-side
-- spend guard; a person buying in the console sees the real total on the
-- checkout page and confirms it there, which is the same guard performed by
-- eye. We still cannot COMPUTE it (no `tax`, no `transactionRatePercentage`),
-- so it must not move to payload_gaps as though a poller change would close
-- it for a manual buy. See docs/buy_side_evo_gotickets.md.
-- ============================================================================

ALTER TABLE public.n2s_buy_intent
  ADD COLUMN IF NOT EXISTS operator_fills text[];

COMMENT ON COLUMN public.n2s_buy_intent.operator_fills IS
  'Fields the human types into the vendor console when placing this buy by '
  'hand. Expected and normal — NOT a defect. Contrast payload_gaps, which is '
  'data OUR side owed and failed to produce.';

COMMENT ON COLUMN public.n2s_buy_intent.payload_gaps IS
  'Data OUR side owed and could not produce (e.g. an unmapped gt_event_id). '
  'A real defect. Fields the human supplies at checkout live in '
  'operator_fills, not here.';

COMMENT ON COLUMN public.n2s_buy_intent.payload_ready IS
  'TRUE when payload_gaps is empty — i.e. everything WE owe is present and the '
  'sheet is complete enough to buy from. It does NOT mean machine-sendable: '
  'nothing in this codebase sends an order, and operator_fills is still the '
  'human''s to complete in the vendor console.';

COMMENT ON TABLE public.n2s_buy_intent IS
  'A human asked to buy a specific cover at a specific price. Records the '
  'frozen cover, the verification verdict AT REQUEST TIME, and a fill sheet: '
  'the fields we know, plus operator_fills naming what the human types into '
  'the vendor console. NOTHING SENDS IT — no upstream call is made from '
  'anywhere in this pipeline. Both vendors DO have purchase APIs (TEvo '
  'Orders/Create; GoTickets Pro POST /orders) and neither is called. '
  'See docs/buy_side_evo_gotickets.md.';

-- ---------------------------------------------------------------------------
-- n2s_buy_intent_create — same verify gate, gaps now split by who owes them.
--
-- DROP first: the RETURNS TABLE gains operator_fills, and CREATE OR REPLACE
-- cannot change a function's return type. The argument list is unchanged, so
-- this drops exactly the one function and leaves no overload behind.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.n2s_buy_intent_create(bigint,text,text);

CREATE FUNCTION public.n2s_buy_intent_create(
  p_n2s_id       bigint,
  p_requested_by text DEFAULT NULL,
  p_notes        text DEFAULT NULL
)
RETURNS TABLE(intent_id bigint, status text, verdict text,
              payload_ready boolean, payload_gaps text[],
              operator_fills text[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  c RECORD; v RECORD; v_gt_event bigint;
  v_gaps  text[] := '{}';   -- ours, and a defect when non-empty
  v_fills text[] := '{}';   -- the human's, and normal when non-empty
  v_payload jsonb;
  v_ready boolean := false;
  v_id bigint;
BEGIN
  SELECT * INTO c FROM public.n2s_cover_queue WHERE n2s_id = p_n2s_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'n2s_buy_intent_create: no queued cover for n2s_id %', p_n2s_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Verify FIRST. gone / order_closed / stale_data cannot become an intent:
  -- "we cannot tell" is not consent to spend money. Unchanged by this
  -- migration — a manual buy still must not start from a dead listing.
  SELECT * INTO v FROM public.n2s_cover_verify(ARRAY[p_n2s_id]) LIMIT 1;
  IF v IS NULL OR NOT COALESCE(v.buyable, false) THEN
    RAISE EXCEPTION 'n2s_buy_intent_create: cover for n2s_id % is not buyable (%)',
      p_n2s_id, COALESCE(v.verdict, 'no verdict') USING ERRCODE = 'check_violation';
  END IF;

  IF c.sub_source = 'tevo' THEN
    -- We can address the listing exactly (ticket_group_id, qty, price). The
    -- rest is the console: who the buyer is, how it is paid, how it ships.
    v_fills := ARRAY['client_id','payment_method','delivery_method','address_id'];
    v_payload := jsonb_build_object(
      'api',              'tevo',
      'endpoint',         'POST /orders',
      'ticket_group_id',  c.sub_listing_id,
      'quantity',         c.sub_qty,
      'price_per_ticket', c.sub_ea,
      'client_id',        NULL,
      'payment_type',     NULL,
      'delivery',         NULL,
      'address_id',       NULL);

  ELSIF c.sub_source = 'gotickets' THEN
    -- The buy side is the Pro API at gotickets.com/rest/pro/api — the SAME
    -- surface gt_listings_poll_tick() already authenticates against. (An
    -- earlier version claimed GoTickets had no purchase API, having read only
    -- gotickets_client.py, which is the SELL-side Broker Sales API.)
    SELECT ge.gt_event_id INTO v_gt_event
      FROM public.gotickets_event ge
     WHERE ge.tevo_event_id = c.tevo_event_id LIMIT 1;
    -- OURS: without this the operator cannot even find the listing page.
    IF v_gt_event IS NULL THEN v_gaps := v_gaps || 'gt_event_id'; END IF;

    v_fills := ARRAY['expectedTotal__confirm_at_checkout','paymentMethodToken',
                     'deliveryMethodId','emailAddress','phoneNumber',
                     'billingAddress','recipient__original_buyer_pii'];
    v_payload := jsonb_build_object(
      'api',                'gotickets_pro',
      'endpoint',           'POST https://gotickets.com/rest/pro/api/orders',
      'eventId',            v_gt_event,
      'listingId',          c.sub_listing_id,
      'quantity',           c.sub_qty,
      'expectedTotal',      NULL,
      'emailAddress',       NULL,
      'phoneNumber',        NULL,
      'deliveryMethodId',   NULL,
      'paymentMethodToken', NULL,
      'billingAddress',     NULL,
      'recipient',          NULL,
      'buyerNotes',         'N2S cover for ' || c.s4k_source || ' order ' || c.order_number,
      '_reference_only',    jsonb_build_object(
          'quoted_ea', c.sub_ea, 'quoted_total', c.sub_total,
          'buy_url', c.buy_url,
          'note', 'quoted_total is the listing price only. The checkout total '
                  'adds tax and the transaction rate — confirm it on the page.'));

  ELSE
    -- SeatGeek / TicketsData surface a match but we hold no purchase path to
    -- them, so there is nothing for a human to open. That IS ours to answer.
    v_gaps := ARRAY['no_purchase_integration_for_' || c.sub_source];
    v_payload := jsonb_build_object('api', c.sub_source, 'endpoint', 'NONE');
  END IF;

  -- "Ready" = we owe nothing further. operator_fills is deliberately NOT part
  -- of this test; if it were, no intent would ever read ready and the flag
  -- would carry no information.
  v_ready := (cardinality(v_gaps) = 0);

  INSERT INTO public.n2s_buy_intent (
    n2s_id, order_number, s4k_source, sub_source, sub_listing_id, tevo_event_id,
    sub_section, sub_row, sub_qty, quoted_ea, quoted_total, cover_cost, buy_url,
    verify_verdict, verify_delta, requested_by, payload, payload_ready,
    payload_gaps, operator_fills, notes)
  VALUES (
    c.n2s_id, c.order_number, c.s4k_source, c.sub_source, c.sub_listing_id,
    c.tevo_event_id, c.sub_section, c.sub_row, c.sub_qty, c.sub_ea,
    c.sub_total, c.cover_cost, c.buy_url,
    v.verdict, v.price_delta_ea, p_requested_by, v_payload, v_ready,
    v_gaps, v_fills, p_notes)
  RETURNING n2s_buy_intent.intent_id INTO v_id;

  RETURN QUERY SELECT v_id, 'requested'::text, v.verdict, v_ready, v_gaps, v_fills;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_buy_intent_create(bigint,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_buy_intent_create(bigint,text,text) TO authenticated, service_role;
