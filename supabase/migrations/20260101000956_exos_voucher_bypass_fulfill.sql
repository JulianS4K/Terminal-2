-- ============================================================================
-- Migration 20260616250000 — Exos (Bridge / D4): voucher bypass at fulfillment
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  REPLACE exos_fulfill_checkout (bypass-aware capacity claim)
-- Pre-reqs: 20260616190000 (fulfill + add-ons), 20260616210000 (vouchers)
--
-- AUDIT FIX (self-audit 2026-06-16, HIGH). A voucher's bypass_capacity was
-- honored at SESSION CREATION (the exos-checkout edge fn skips the tier cap),
-- but NOT at FULFILLMENT — exos_fulfill_checkout still hard-enforced both the
-- tier cap and the event house cap. So a buyer redeeming a bypass voucher on a
-- genuinely sold-out tier paid via Stripe, then the webhook marked the order
-- 'failed' ("sold out at fulfillment") — charged, no ticket. (The waitlist
-- auto-assign path didn't hit this because the refund frees capacity first.)
--
-- Fix: when the session carries a bypass_capacity voucher, increment sold
-- counters WITHOUT the cap guards (deliberate oversell), mirroring the edge-fn
-- behavior end-to-end. Body otherwise identical to mig 20260616190000.
-- D4 authors; A1 applies to prod.
-- ============================================================================
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

  -- A bypass_capacity voucher on the session lets it exceed the caps (the same
  -- grant the edge fn applied at checkout — now honored end-to-end).
  IF s.voucher_id IS NOT NULL THEN
    SELECT bypass_capacity INTO v_bypass FROM public.exos_vouchers WHERE id = s.voucher_id;
    v_bypass := coalesce(v_bypass, false);
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
