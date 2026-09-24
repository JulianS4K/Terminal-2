-- ============================================================================
-- Migration 20260924205916 — Exos (Bridge / D4): P0 — cart holds can't hoard
-- Already applied to prod via Supabase MCP on 2026-09-24 (operator-approved, Exos P0 + all-in; Terminal-2 #1003).
--                            an event's inventory
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_create_hold (replaced), exos_cart_holds (releases prior holds),
--              EXECUTE grant on exos_assert_purchase_limit (revoked from authenticated)
--           R: exos_events, exos_ticket_tiers, exos_quotas, exos_quota_tiers, auth.users
-- Pre-reqs: 20260702123000 (cart holds), 20260702123200 (exos_create_hold body),
--           20260702122000 (exos_assert_purchase_limit)
--
-- P0 (audit 2026-09-24, HIGH). exos_create_hold is callable by any signed-up
-- user and had no per-buyer cap: 10 seats a call, TTL up to an hour, no limit
-- on live holds, no purchase-limit check. A script could "sell out" any event
-- and re-hold it every hour. pretix bounds this with one cart per session and a
-- reservation timeout; the same shape here:
--   * One live hold per buyer per event: a new hold releases the buyer's
--     earlier live holds for that event (a new checkout replaces the old cart).
--   * The event's purchase limits (maxPerOrder / maxPerAccount, counted against
--     tickets already held) apply at hold time, not only at payment.
--   * The buyer's email must be confirmed, so each fake account costs an inbox.
--   * TTL is capped at 30 minutes (was 60), matching the Stripe session expiry
--     set by exos-checkout.
-- Also (audit LOW): exos_assert_purchase_limit was EXECUTE-able by any user for
-- any p_buyer and its error text leaks that buyer's ticket count; only the
-- service-role checkout calls it directly, so authenticated loses EXECUTE.
--
-- Residual: many confirmed accounts can still each hold one cart per event.
-- Per-event hold ceilings / rate limits are a follow-up if that shows up.
--
-- Idempotent: CREATE OR REPLACE + REVOKE. D4 authors; applying to prod is operator-gated.
-- ============================================================================

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
  v_ttl    int := LEAST(GREATEST(coalesce(p_ttl_seconds, 1800), 60), 1800);  -- clamp 1..30 min
  v_id     uuid;
  q        record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_hold: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_create_hold: confirm your email before reserving tickets' USING ERRCODE = '42501';
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

  -- Serialize this buyer's holds for this event, then retire their old cart so
  -- it neither counts against availability nor stacks with the new one.
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_hold:' || p_event_id::text || ':' || v_uid::text, 0));
  UPDATE public.exos_cart_holds
     SET status = 'released', released_at = now()
   WHERE event_id = p_event_id AND buyer_uid = v_uid AND status = 'active';

  -- maxPerOrder / maxPerAccount (the latter counts tickets already held).
  PERFORM public.exos_assert_purchase_limit(p_event_id, v_uid, p_quantity);

  FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id LOOP
    PERFORM 1 FROM public.exos_quotas WHERE id = q.quota_id FOR UPDATE;
  END LOOP;

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

REVOKE EXECUTE ON FUNCTION public.exos_assert_purchase_limit(uuid, uuid, int) FROM authenticated;
