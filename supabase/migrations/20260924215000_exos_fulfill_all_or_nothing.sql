-- ============================================================================
-- Migration 20260924215000 — Exos (Bridge / D4): P1 — fulfillment is
--                            all-or-nothing, and add-ons can't oversell
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_fulfill_checkout (replaced)
--           R/W: exos_checkout_sessions, exos_vouchers, exos_waitlist, exos_cart_holds,
--                exos_ticket_tiers, exos_events, exos_tickets, exos_event_addons, exos_order_addons
-- Pre-reqs: 20260702123200 (tier-1 fulfill body), 20260924205508 (consume_voucher(id, qty))
--
-- Audit 2026-09-24 (P1). Three bugs, one cause: fulfillment claimed inventory
-- step by step and, on a later step's failure, marked the session failed and
-- RETURNed. That commits the earlier steps:
--   * add-ons were never capacity-checked ("buyer already paid"), so two
--     concurrent checkouts that both read "1 left" both got it;
--   * a failed event house cap left the tier's `sold` bumped (seats vanish);
--   * a voucher consumed before a sold-out failure stayed consumed, and its
--     waitlist row stayed 'converted' (the buyer is refunded but loses the code).
-- Now every claim runs in one sub-transaction. Any failure raises XF001, which
-- rolls the whole claim back; the session is then marked failed (the webhook
-- auto-refunds failed paid sessions) and its cart holds are released, so the
-- seats return at once instead of at hold expiry. Add-ons claim with the same
-- atomic "capacity = 0 OR sold + qty <= capacity" update as tiers; a bypass
-- voucher lifts ticket caps only, not add-on stock.
--
-- Same signature, grants and return contract (ticket ids; '{}' on failure).
-- D4 authors; applying to prod is operator-gated.
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
  v_fail     text;
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

  BEGIN  -- all-or-nothing claim: any RAISE ... 'XF001' undoes every step below
    BEGIN
      PERFORM public.exos_assert_purchase_limit(s.event_id, s.buyer_uid, s.quantity);
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'per-account purchase limit exceeded at fulfillment' USING ERRCODE = 'XF001';
    END;

    IF s.voucher_id IS NOT NULL THEN
      SELECT bypass_capacity INTO v_bypass FROM public.exos_vouchers WHERE id = s.voucher_id;
      v_bypass := coalesce(v_bypass, false);
      IF NOT public.exos_consume_voucher(s.voucher_id, s.quantity) THEN
        RAISE EXCEPTION 'voucher already fully redeemed' USING ERRCODE = 'XF001';
      END IF;
      UPDATE public.exos_waitlist SET status = 'converted'
       WHERE voucher_id = s.voucher_id AND status = 'offered';
    END IF;

    -- The session's own hold stops counting against the quota check below.
    PERFORM public.exos_consume_holds_for_session(p_session_id);

    IF NOT v_bypass THEN
      BEGIN
        PERFORM public.exos_assert_quota(s.tier_id, s.quantity);
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'shared quota exhausted at fulfillment' USING ERRCODE = 'XF001';
      END;
    END IF;

    IF s.tier_id IS NOT NULL THEN
      UPDATE public.exos_ticket_tiers
         SET sold = sold + s.quantity
       WHERE id = s.tier_id AND event_id = s.event_id
         AND (v_bypass OR capacity = 0 OR sold + s.quantity <= capacity)
      RETURNING name INTO v_tier_name;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'tier sold out at fulfillment' USING ERRCODE = 'XF001';
      END IF;
    END IF;

    UPDATE public.exos_events
       SET tickets_sold = tickets_sold + s.quantity
     WHERE id = s.event_id
       AND (v_bypass OR total_tickets = 0 OR tickets_sold + s.quantity <= total_tickets);
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
      RAISE EXCEPTION 'event sold out at fulfillment' USING ERRCODE = 'XF001';
    END IF;

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

    IF s.addons IS NOT NULL AND jsonb_typeof(s.addons) = 'array' THEN
      FOR r IN
        SELECT * FROM jsonb_to_recordset(s.addons)
          AS x(addon_id uuid, quantity int, unit_price_cents int, name text)
      LOOP
        IF r.addon_id IS NULL OR coalesce(r.quantity, 0) < 1 THEN CONTINUE; END IF;
        UPDATE public.exos_event_addons
           SET sold = sold + r.quantity
         WHERE id = r.addon_id AND event_id = s.event_id
           AND (capacity = 0 OR sold + r.quantity <= capacity);
        IF NOT FOUND THEN
          RAISE EXCEPTION 'add-on "%" sold out at fulfillment', left(coalesce(r.name, '?'), 80)
            USING ERRCODE = 'XF001';
        END IF;
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
  EXCEPTION WHEN SQLSTATE 'XF001' THEN
    v_fail := SQLERRM;
  END;

  IF v_fail IS NOT NULL THEN
    UPDATE public.exos_cart_holds
       SET status = 'released', released_at = now()
     WHERE checkout_session_id = p_session_id AND status = 'active';
    UPDATE public.exos_checkout_sessions
       SET status = 'failed', failure_reason = left(v_fail, 500)
     WHERE session_id = p_session_id;
    RETURN '{}'::uuid[];
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
