-- ============================================================================
-- Migration 20260702123200 — Exos (Bridge / D4): wire Tier-1 holds + quotas
--                            into the fulfillment / mint / hold paths
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  REPLACE exos_create_hold (quota-aware), REPLACE exos_fulfill_checkout
--           (consume holds + assert quota before mint), REPLACE exos_mint_tickets
--           (assert quota); reads exos_cart_holds / exos_quotas / exos_quota_tiers.
-- Pre-reqs: 20260702123000 (holds + exos_consume_holds_for_session),
--           20260702123030 (quotas + exos_assert_quota / exos_effective_available),
--           20260702123100 (payment ledger — sibling, not required here),
--           20260702122000 (latest exos_fulfill_checkout body — voucher/limit),
--           20260523180000 (latest exos_mint_tickets body — purchase limits)
--
-- The three Tier-1 migrations (holds/quotas/ledger) added the tables + primitives
-- but were deliberately PURELY ADDITIVE — the hot mint/fulfill paths were left
-- untouched. This migration performs the documented wiring so holds actually
-- convert to sales and shared quotas are actually enforced end-to-end.
--
-- Each replaced body is the CURRENT prod definition (per the Pre-reqs above) with
-- ONLY the additions below — no other behavior changed:
--   • exos_create_hold   → now reserves against exos_effective_available (tier
--                          capacity AND every shared quota), not just tier cap.
--   • exos_fulfill_checkout → consumes the session's cart hold(s) then asserts
--                          the shared quota BEFORE minting (skipped for a
--                          bypass-voucher, like the other caps); on quota
--                          exhaustion marks the session 'failed' (NOT raise — a
--                          raise 500s the webhook into an infinite Stripe retry).
--   • exos_mint_tickets  → asserts the shared quota before the tier claim
--                          (platform admins bypass, mirroring purchase-limit).
--
-- LOCK ORDER (deadlock-safety): every path takes locks quota → tier → event, and
-- asserts the quota BEFORE incrementing `sold` (so a sale is never double-counted)
-- and AFTER consuming the session's own hold (so the reservation doesn't
-- self-block its own fulfillment). Concurrency verified on a local PG replay.
--
-- D4 authors; A1 applies to prod. ⚠ B1 review requested (hot-path change).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. exos_create_hold — quota-aware. Locks the mapped quota rows THEN the tier
--    row (quota→tier, matching fulfillment/mint), then reserves iff
--    exos_effective_available (tier capacity ∧ every shared quota) has room.
--    Signature unchanged. Supersedes mig 20260702123000.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_create_hold(
  p_event_id     uuid,
  p_tier_id      uuid,
  p_quantity     int DEFAULT 1,
  p_ttl_seconds  int DEFAULT 1800
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_email  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_org    uuid;
  v_status text;
  v_sstart timestamptz;
  v_send   timestamptz;
  v_avail  int;
  v_ttl    int := LEAST(GREATEST(coalesce(p_ttl_seconds, 1800), 60), 3600);  -- clamp 1min..1hr
  v_id     uuid;
  q        record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_hold: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_quantity < 1 OR p_quantity > 10 THEN
    RAISE EXCEPTION 'exos_create_hold: quantity must be 1-10';
  END IF;

  SELECT org_id, status INTO v_org, v_status FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_create_hold: event not found';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_create_hold: event not on sale' USING ERRCODE = '23514';
  END IF;

  -- Lock the tier's mapped quota rows FIRST (quota→tier order), so concurrent
  -- holds on sibling tiers sharing a quota serialize consistently with mint/fulfill.
  FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id LOOP
    PERFORM 1 FROM public.exos_quotas WHERE id = q.quota_id FOR UPDATE;
  END LOOP;

  -- Then lock the tier row → serializes concurrent holds/claims for this tier.
  SELECT sales_start, sales_end INTO v_sstart, v_send
    FROM public.exos_ticket_tiers
   WHERE id = p_tier_id AND event_id = p_event_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_create_hold: tier not found for this event';
  END IF;
  IF v_sstart IS NOT NULL AND now() < v_sstart THEN
    RAISE EXCEPTION 'exos_create_hold: sales have not started for this tier' USING ERRCODE = '23514';
  END IF;
  IF v_send IS NOT NULL AND now() > v_send THEN
    RAISE EXCEPTION 'exos_create_hold: sales have ended for this tier' USING ERRCODE = '23514';
  END IF;

  -- Effective availability under the locks (tier capacity ∧ shared quotas).
  -- NULL = uncapped by every source → unlimited. The pending hold is not yet
  -- inserted, so it is correctly excluded from this number.
  v_avail := public.exos_effective_available(p_tier_id);
  IF v_avail IS NOT NULL AND v_avail < p_quantity THEN
    RAISE EXCEPTION 'exos_create_hold: not enough tickets available' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, expires_at)
  VALUES (p_event_id, p_tier_id, v_org, v_uid, NULLIF(v_email, ''), p_quantity, now() + make_interval(secs => v_ttl))
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_create_hold(uuid, uuid, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_create_hold(uuid, uuid, int, int) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_hold(uuid, uuid, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. exos_fulfill_checkout — current body (mig 20260702122000) + two additions,
--    marked  -- [TIER-1] : consume the session's hold(s), then assert the shared
--    quota (skipped on bypass) BEFORE the tier claim. Everything else verbatim.
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

  -- Per-account purchase limit, re-checked at fulfillment.
  BEGIN
    PERFORM public.exos_assert_purchase_limit(s.event_id, s.buyer_uid, s.quantity);
  EXCEPTION WHEN others THEN
    UPDATE public.exos_checkout_sessions
       SET status='failed', failure_reason='per-account purchase limit exceeded at fulfillment'
     WHERE session_id = p_session_id;
    RETURN '{}'::uuid[];
  END;

  -- A bypass_capacity voucher on the session lets it exceed the caps.
  IF s.voucher_id IS NOT NULL THEN
    SELECT bypass_capacity INTO v_bypass FROM public.exos_vouchers WHERE id = s.voucher_id;
    v_bypass := coalesce(v_bypass, false);

    IF NOT public.exos_consume_voucher(s.voucher_id) THEN
      UPDATE public.exos_checkout_sessions
         SET status='failed', failure_reason='voucher already fully redeemed'
       WHERE session_id = p_session_id;
      RETURN '{}'::uuid[];
    END IF;

    UPDATE public.exos_waitlist SET status = 'converted'
     WHERE voucher_id = s.voucher_id AND status = 'offered';
  END IF;

  -- [TIER-1] Consume this session's cart hold(s): the reserved inventory now
  -- converts to a real sale, and (crucially) the hold stops counting against the
  -- quota assert below — otherwise the session's own reservation would block it.
  -- Idempotent (webhook retry).
  PERFORM public.exos_consume_holds_for_session(p_session_id);

  -- [TIER-1] Shared-quota gate (skipped on a bypass voucher, like the other caps).
  -- BEFORE the tier `sold` bump so this sale isn't double-counted. Marked failed
  -- (not raised) on exhaustion so the webhook doesn't 500 into a Stripe retry.
  IF NOT v_bypass THEN
    BEGIN
      PERFORM public.exos_assert_quota(s.tier_id, s.quantity);
    EXCEPTION WHEN others THEN
      UPDATE public.exos_checkout_sessions
         SET status='failed', failure_reason='shared quota exhausted at fulfillment'
       WHERE session_id = p_session_id;
      RETURN '{}'::uuid[];
    END;
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

-- ---------------------------------------------------------------------------
-- 3. exos_mint_tickets — current body (mig 20260523180000) + one addition,
--    marked  -- [TIER-1] : assert the shared quota before the tier claim
--    (quota→tier order). Platform admins bypass (comp blocks), mirroring the
--    purchase-limit bypass just above it. Everything else verbatim.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_mint_tickets(
  p_event_id    uuid,
  p_tier_id     uuid    DEFAULT NULL,
  p_quantity    int     DEFAULT 1,
  p_order_ref   text    DEFAULT NULL,
  p_price_paid  numeric DEFAULT NULL,
  p_promoter_id text    DEFAULT NULL
) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_org       uuid;
  v_tier_name text;
  v_ids       uuid[] := '{}';
  v_id        uuid;
  v_updated   int;
  i           int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_mint_tickets: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_quantity < 1 OR p_quantity > 10 THEN
    RAISE EXCEPTION 'exos_mint_tickets: quantity must be 1-10';
  END IF;

  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_mint_tickets: event not found';
  END IF;

  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_mint_tickets: not authorized for this event' USING ERRCODE = '42501';
  END IF;

  -- Per-person purchase limit (cumulative). Platform admins bypass for comp blocks.
  IF NOT exos_is_admin() THEN
    PERFORM public.exos_assert_purchase_limit(p_event_id, v_uid, p_quantity);
  END IF;

  -- [TIER-1] Shared-quota gate before the tier claim (quota→tier lock order).
  -- Platform admins bypass (comp blocks), mirroring the purchase-limit bypass.
  IF NOT exos_is_admin() THEN
    PERFORM public.exos_assert_quota(p_tier_id, p_quantity);
  END IF;

  IF p_tier_id IS NOT NULL THEN
    UPDATE public.exos_ticket_tiers
       SET sold = sold + p_quantity
     WHERE id = p_tier_id
       AND event_id = p_event_id
       AND (capacity = 0 OR sold + p_quantity <= capacity)
    RETURNING name INTO v_tier_name;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos_mint_tickets: tier sold out or not found for this event';
    END IF;
  END IF;

  UPDATE public.exos_events
     SET tickets_sold = tickets_sold + p_quantity
   WHERE id = p_event_id
     AND (total_tickets = 0 OR tickets_sold + p_quantity <= total_tickets);
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'exos_mint_tickets: event sold out — total_tickets cap reached'
      USING ERRCODE = '23514';
  END IF;

  FOR i IN 1..p_quantity LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source, promoter_id
    ) VALUES (
      p_event_id, v_org, p_tier_id, v_tier_name, v_uid, v_uid,
      lower(coalesce(auth.jwt() ->> 'email', '')),
      'active', gen_random_uuid()::text, coalesce(p_price_paid, 0),
      p_order_ref, 'vibepass', p_promoter_id
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  RETURN v_ids;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_mint_tickets(uuid, uuid, int, text, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_mint_tickets(uuid, uuid, int, text, numeric, text) TO authenticated;

-- ROLLBACK: recreate exos_create_hold from mig 20260702123000,
-- exos_fulfill_checkout from mig 20260702122000, and exos_mint_tickets from
-- mig 20260523180000 (drop the [TIER-1] additions).
