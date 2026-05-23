-- ============================================================================
-- Migration 20260523180000 — Exos (Bridge / D4): enforce per-person buy limits
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_assert_purchase_limit() (W, new),
--           exos_mint_tickets() (CREATE OR REPLACE — same signature)
-- Pre-reqs: 20260520120000 (exos_events.purchase_limits),
--           20260523150000 (exos_mint_tickets event-cap version)
--
-- Finding (sim 2026-05-23): exos_events.purchase_limits ({maxPerOrder,
-- maxPerAccount}) was enforced ONLY client-side (EventDetails), so a buyer
-- could acquire the whole allocation in batches — and a SECOND buy attempt was
-- not capped against tickets already held. Enforce it server-side.
--
-- Semantics (matches the UI contract; both keys optional, 0/NULL = unlimited):
--   maxPerOrder   — max tickets in one mint/purchase call.
--   maxPerAccount — max tickets a person may HOLD for the event, counted
--                   CUMULATIVELY over their existing non-voided tickets. This
--                   is what blocks a second buy that would push them over.
--
-- exos_mint_tickets is the org-staff/admin COMP path; platform admins
-- (exos_is_admin) bypass the limit so they can issue comp blocks, but org
-- owner/manager comps are subject to the event's configured limit. The buyer
-- (Stripe) path enforces the same limit in the exos-checkout edge fn pre-check.
--
-- D4 authors; A1 applies to prod.
-- ============================================================================

-- Reusable limit check. Raises (ERRCODE 23514) on violation; no-op when the
-- event has no purchase_limits configured.
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

-- exos_mint_tickets: event-cap (mig 150000) + per-person purchase limit (admin bypass).
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
