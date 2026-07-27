-- ============================================================================
-- Migration 20260702122000 — Exos (Bridge / D4): atomic voucher single-use +
--                            purchase-limit re-check at fulfillment
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  REPLACE exos_assert_purchase_limit (advisory lock),
--           REPLACE exos_fulfill_checkout (consume-before-mint + limit re-check),
--           DROP TRIGGER exos_checkout_consume_voucher (now redundant)
-- Pre-reqs: 20260523180000 (purchase limit), 20260616210000 (vouchers +
--           consume trigger), 20260616250000 (bypass-aware fulfillment)
--
-- SECURITY FIX (audit 2026-07-02).
--
--   1. Voucher single-use bypass (HIGH). A voucher was validated read-only at
--      checkout-create and "consumed" by an AFTER-UPDATE trigger whose boolean
--      result was discarded. A holder of one single-use voucher could open N
--      sessions before paying (all see used_count=0), pay all N, and every
--      fulfillment minted — oversell a sold-out event N times (bypass_capacity)
--      or redeem a comp price_override N times. Fix: consume the voucher INSIDE
--      exos_fulfill_checkout, row-locked, BEFORE minting, and FAIL the session
--      if it is already exhausted. The consume UPDATE serializes concurrent
--      fulfillments on the voucher row, so exactly max_uses of them succeed. The
--      old AFTER trigger is dropped to avoid a double consume.
--
--   2. maxPerAccount bypass (MED). exos_assert_purchase_limit did a bare
--      count-then-insert with no lock, and fulfillment never re-checked it, so
--      concurrent sessions/claims each passed. Fix: (a) a per-(event,buyer)
--      advisory xact lock in exos_assert_purchase_limit so the count+mint is
--      serialized for all callers (paid, comp, free); (b) fulfillment now calls
--      exos_assert_purchase_limit before minting and, on violation, marks the
--      session failed (NOT raise — a raise would 500 the webhook into an
--      infinite Stripe retry).
--
-- D4 authors; A1 applies to prod.
-- ============================================================================

-- Drop the redundant post-mint consume trigger (fulfillment now consumes).
DROP TRIGGER IF EXISTS exos_checkout_consume_voucher ON public.exos_checkout_sessions;

-- ---------------------------------------------------------------------------
-- exos_assert_purchase_limit — now atomic. A per-(event,buyer) advisory xact
-- lock (held to commit) serializes the count+subsequent-insert against
-- concurrent callers, closing the read-modify-write race. Body otherwise
-- identical to mig 20260523180000.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_assert_purchase_limit(
  p_event_id uuid,
  p_buyer    uuid,
  p_qty      int
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_lim       jsonb;
  v_max_order int;
  v_max_acct  int;
  v_have      int;
BEGIN
  SELECT purchase_limits INTO v_lim FROM public.exos_events WHERE id = p_event_id;
  IF v_lim IS NULL THEN
    RETURN;  -- no limits configured for this event
  END IF;

  v_max_order := nullif(v_lim ->> 'maxPerOrder', '')::int;
  v_max_acct  := nullif(v_lim ->> 'maxPerAccount', '')::int;

  IF v_max_order IS NOT NULL AND v_max_order > 0 AND p_qty > v_max_order THEN
    RAISE EXCEPTION 'exos: exceeds max per order (% requested, limit %)', p_qty, v_max_order
      USING ERRCODE = '23514';
  END IF;

  IF v_max_acct IS NOT NULL AND v_max_acct > 0 THEN
    -- Serialize concurrent purchase-limit checks for this (event, buyer) so the
    -- count-then-insert can't race two callers past the cap. Transaction-scoped:
    -- released at commit, after the caller's INSERT/mint has landed.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text || ':' || p_buyer::text, 0));
    -- Cumulative: tickets this buyer already HOLDS for the event (non-voided).
    SELECT count(*) INTO v_have
      FROM public.exos_tickets
     WHERE event_id = p_event_id AND owner_id = p_buyer AND status <> 'voided';
    IF v_have + p_qty > v_max_acct THEN
      RAISE EXCEPTION 'exos: exceeds max per account (hold %, +% would exceed limit %)',
        v_have, p_qty, v_max_acct USING ERRCODE = '23514';
    END IF;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.exos_assert_purchase_limit(uuid, uuid, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_assert_purchase_limit(uuid, uuid, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- exos_fulfill_checkout — consume the voucher (row-locked) and re-check the
-- per-account limit BEFORE minting. Body otherwise identical to mig
-- 20260616250000 (bypass-aware capacity claim).
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
  v_evname   text;
  v_safe     text;
  v_bypass   boolean := false;
  i          int;
  r          record;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: unknown session %', p_session_id;
  END IF;

  IF s.status = 'fulfilled' THEN
    RETURN coalesce(s.ticket_ids, '{}');
  END IF;
  IF s.status <> 'pending' THEN
    RETURN '{}'::uuid[];
  END IF;

  -- Per-account purchase limit, re-checked at fulfillment (concurrent pending
  -- sessions each passed the check at create time). Marked failed (not raised)
  -- on violation so the webhook doesn't 500 into an infinite Stripe retry.
  BEGIN
    PERFORM public.exos_assert_purchase_limit(s.event_id, s.buyer_uid, s.quantity);
  EXCEPTION WHEN others THEN
    UPDATE public.exos_checkout_sessions
       SET status='failed', failure_reason='per-account purchase limit exceeded at fulfillment'
     WHERE session_id = p_session_id;
    RETURN '{}'::uuid[];
  END;

  -- A bypass_capacity voucher on the session lets it exceed the caps (the same
  -- grant the edge fn applied at checkout — now honored end-to-end).
  IF s.voucher_id IS NOT NULL THEN
    SELECT bypass_capacity INTO v_bypass FROM public.exos_vouchers WHERE id = s.voucher_id;
    v_bypass := coalesce(v_bypass, false);

    -- Consume the voucher use ATOMICALLY before minting. The row-locked UPDATE
    -- inside exos_consume_voucher serializes concurrent fulfillments sharing one
    -- voucher, so exactly max_uses succeed; the rest fail here without minting.
    IF NOT public.exos_consume_voucher(s.voucher_id) THEN
      UPDATE public.exos_checkout_sessions
         SET status='failed', failure_reason='voucher already fully redeemed'
       WHERE session_id = p_session_id;
      RETURN '{}'::uuid[];
    END IF;

    -- Convert the waitlist row this voucher was offered to. Parity with the old
    -- consume trigger (mig 20260616220000) which did consume + convert together;
    -- both now live in the fulfillment path, in the same transaction as the mint.
    UPDATE public.exos_waitlist SET status = 'converted'
     WHERE voucher_id = s.voucher_id AND status = 'offered';
  END IF;

  -- Tier capacity claim (atomic). NULL tier = no per-tier cap. Bypass = no cap.
  IF s.tier_id IS NOT NULL THEN
    IF v_bypass THEN
      UPDATE public.exos_ticket_tiers
         SET sold = sold + s.quantity
       WHERE id = s.tier_id AND event_id = s.event_id
      RETURNING name INTO v_tier_name;
    ELSE
      UPDATE public.exos_ticket_tiers
         SET sold = sold + s.quantity
       WHERE id = s.tier_id AND event_id = s.event_id
         AND (capacity = 0 OR sold + s.quantity <= capacity)
      RETURNING name INTO v_tier_name;
    END IF;
    IF NOT FOUND THEN
      UPDATE public.exos_checkout_sessions
         SET status='failed', failure_reason='tier sold out at fulfillment'
       WHERE session_id = p_session_id;
      RETURN '{}'::uuid[];
    END IF;
  END IF;

  -- Event house cap (atomic). Bypass = no cap.
  IF v_bypass THEN
    UPDATE public.exos_events SET tickets_sold = tickets_sold + s.quantity WHERE id = s.event_id;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
  ELSE
    UPDATE public.exos_events
       SET tickets_sold = tickets_sold + s.quantity
     WHERE id = s.event_id
       AND (total_tickets = 0 OR tickets_sold + s.quantity <= total_tickets);
    GET DIAGNOSTICS v_updated = ROW_COUNT;
  END IF;
  IF v_updated = 0 THEN
    UPDATE public.exos_checkout_sessions
       SET status='failed', failure_reason='event sold out at fulfillment'
     WHERE session_id = p_session_id;
    RETURN '{}'::uuid[];
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
      round((s.amount_cents::numeric / 100) / s.quantity, 2),
      p_session_id, 'stripe'
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  -- Fulfill add-ons (buyer already paid → record + bump sold, no cap re-check).
  IF s.addons IS NOT NULL AND jsonb_typeof(s.addons) = 'array' THEN
    FOR r IN
      SELECT * FROM jsonb_to_recordset(s.addons)
        AS x(addon_id uuid, quantity int, unit_price_cents int, name text)
    LOOP
      IF r.addon_id IS NULL OR coalesce(r.quantity, 0) < 1 THEN CONTINUE; END IF;
      UPDATE public.exos_event_addons
         SET sold = sold + r.quantity
       WHERE id = r.addon_id AND event_id = s.event_id;
      INSERT INTO public.exos_order_addons (
        event_id, org_id, addon_id, addon_name, buyer_id, owner_id,
        quantity, unit_price_paid, order_ref, channel_source, status
      ) VALUES (
        s.event_id, s.org_id, r.addon_id, r.name, s.buyer_uid, s.buyer_uid,
        r.quantity, round(coalesce(r.unit_price_cents, 0)::numeric / 100, 2),
        p_session_id, 'stripe', 'active'
      );
    END LOOP;
  END IF;

  UPDATE public.exos_checkout_sessions
     SET status='fulfilled', ticket_ids=v_ids, fulfilled_at=now()
   WHERE session_id = p_session_id;

  -- Buyer confirmation mail (best-effort; never unwinds a paid fulfillment).
  IF coalesce(s.buyer_email, '') <> '' THEN
    SELECT name INTO v_evname FROM public.exos_events WHERE id = s.event_id;
    v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');
    BEGIN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES (
        'ticket-issued', lower(s.buyer_email),
        left('Your ticket' || CASE WHEN s.quantity > 1 THEN 's' ELSE '' END ||
             ' for ' || v_safe || ' ' || CASE WHEN s.quantity > 1 THEN 'are' ELSE 'is' END || ' ready', 200),
        '<p>Payment received — your ' || s.quantity::text || ' ticket' ||
          CASE WHEN s.quantity > 1 THEN 's' ELSE '' END ||
          ' for <strong>' || v_safe ||
          '</strong> ' || CASE WHEN s.quantity > 1 THEN 'are' ELSE 'is' END ||
          ' in your wallet. Open the app to show your QR at the door.</p>',
        s.buyer_uid, 'pending'
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  RETURN v_ids;
END $$;
REVOKE ALL ON FUNCTION public.exos_fulfill_checkout(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_fulfill_checkout(text) TO service_role;

-- ROLLBACK: recreate exos_assert_purchase_limit from mig 20260523180000 and
-- exos_fulfill_checkout from mig 20260616250000, and recreate the trigger
-- exos_checkout_consume_voucher from mig 20260616210000.
