-- ============================================================================
-- Migration 20260924205508 — Exos (Bridge / D4): P0 — a voucher use buys one
--                            ticket, and waitlist offers reserve their seats
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_vouchers (+block_quota), FUNCTION exos_consume_voucher (+ (uuid,int) overload),
--              FUNCTION exos_fulfill_checkout (patched in place: consume per ticket),
--              FUNCTION exos_tier_available, exos_quota_available (subtract blocking vouchers),
--              FUNCTION _exos_waitlist_offer_core, exos_tg_waitlist_autooffer (replaced)
--           R: exos_waitlist, exos_ticket_tiers, exos_quota_tiers, exos_cart_holds, exos_tickets
-- Pre-reqs: 20260616210000 (vouchers), 20260616220000 (waitlist auto-offer),
--           20260702123000 (cart holds), 20260702123030 (quotas), 20260702123200 (fulfill)
--
-- P0 (audit 2026-09-24, HIGH). Three ways a voucher oversold an event:
--   1. A "use" was counted per ORDER: exos_fulfill_checkout consumed one use
--      then minted s.quantity (up to 10) tickets. A single-use capacity-bypass
--      voucher therefore minted 10 tickets past sold-out. Now one use = one
--      ticket (pretix's model): fulfillment consumes s.quantity uses atomically.
--   2. Waitlist offers were always max_uses 1 whatever the waitlister asked for,
--      and _exos_waitlist_offer_core offered N ROWS for N freed SEATS. Offers
--      now carry the row's quantity and stop once the freed seats are covered
--      (FIFO: a group that doesn't fit waits rather than being skipped).
--   3. An offer bypasses capacity but reserved nothing, so a regular buyer
--      could take the freed seat AND the waitlister could still buy it. Offer
--      vouchers now set block_quota (pretix's name for the same idea) and their
--      unredeemed, unexpired uses count against tier and quota availability,
--      exactly like live cart holds. Organizer comp vouchers are unchanged.
--   Also: the auto-offer trigger offered the raw sold delta, even on a tier
--   still oversold; it now offers the tier's real availability (net of holds
--   and outstanding offers) whenever seats free up.
--
-- Known limit: a tier-less offer (event-level waitlist, tier_id NULL) doesn't
-- block a specific tier, since it has none to block.
--
-- exos_fulfill_checkout is patched from its live definition (pg_get_functiondef)
-- rather than restated, so the rest of that long body is guaranteed unchanged;
-- the block raises if the call it rewrites isn't found exactly once.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, and the fulfill patch
-- is a no-op once applied. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- 0. Offer vouchers hold their seats (pretix: Voucher.block_quota) ------------
ALTER TABLE public.exos_vouchers
  ADD COLUMN IF NOT EXISTS block_quota boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.exos_vouchers.block_quota IS
  'Unredeemed, unexpired uses of this voucher count against tier/quota availability (waitlist offers). mig 20260924205508.';
CREATE INDEX IF NOT EXISTS exos_vouchers_blocking_idx
  ON public.exos_vouchers (tier_id) WHERE block_quota;

-- 1. One use = one ticket -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_consume_voucher(p_voucher_id uuid, p_uses int)
RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE v_rows int;
BEGIN
  IF p_voucher_id IS NULL OR coalesce(p_uses, 0) < 1 THEN RETURN false; END IF;
  UPDATE public.exos_vouchers
     SET used_count = used_count + p_uses
   WHERE id = p_voucher_id AND used_count + p_uses <= max_uses;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_consume_voucher(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_consume_voucher(uuid, int) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_consume_voucher(p_voucher_id uuid)
RETURNS boolean
  LANGUAGE sql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$ SELECT public.exos_consume_voucher(p_voucher_id, 1) $$;
REVOKE ALL ON FUNCTION public.exos_consume_voucher(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_consume_voucher(uuid) TO service_role;

DO $$
DECLARE
  v_def text := pg_get_functiondef('public.exos_fulfill_checkout(text)'::regprocedure);
  v_old text := 'public.exos_consume_voucher(s.voucher_id)';
  v_new text := 'public.exos_consume_voucher(s.voucher_id, s.quantity)';
  v_hits int;
BEGIN
  IF position(v_new in v_def) > 0 THEN
    RETURN;   -- already patched
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: expected exactly one % call, found %', v_old, v_hits;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- 2. Availability subtracts blocking vouchers (next to live cart holds) -------
CREATE OR REPLACE FUNCTION public.exos_tier_available(p_tier_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
           WHEN t.capacity = 0 THEN NULL                       -- uncapped
           ELSE GREATEST(0, t.capacity - t.sold - COALESCE(h.held, 0) - COALESCE(v.blocked, 0))
         END
  FROM public.exos_ticket_tiers t
  LEFT JOIN (
    SELECT tier_id, SUM(quantity) AS held
    FROM public.exos_cart_holds
    WHERE tier_id = p_tier_id AND status = 'active' AND expires_at > now()
    GROUP BY tier_id
  ) h ON h.tier_id = t.id
  LEFT JOIN (
    SELECT tier_id, SUM(max_uses - used_count) AS blocked
    FROM public.exos_vouchers
    WHERE tier_id = p_tier_id AND block_quota AND used_count < max_uses
      AND (valid_until IS NULL OR valid_until > now())
    GROUP BY tier_id
  ) v ON v.tier_id = t.id
  WHERE t.id = p_tier_id;
$$;
REVOKE EXECUTE ON FUNCTION public.exos_tier_available(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_tier_available(uuid) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_quota_available(p_quota_id uuid)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_size    int;
  v_closed  boolean;
  v_used    int;
  v_held    int;
  v_blocked int;
BEGIN
  SELECT size, closed INTO v_size, v_closed FROM public.exos_quotas WHERE id = p_quota_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_closed THEN
    RETURN 0;
  END IF;
  IF v_size IS NULL THEN
    RETURN NULL;               -- unlimited pool
  END IF;

  SELECT COUNT(*) INTO v_used
    FROM public.exos_tickets t
   WHERE t.tier_id IN (SELECT tier_id FROM public.exos_quota_tiers WHERE quota_id = p_quota_id)
     AND t.status IN ('active','used','transferred');

  SELECT COALESCE(SUM(h.quantity), 0) INTO v_held
    FROM public.exos_cart_holds h
   WHERE h.tier_id IN (SELECT tier_id FROM public.exos_quota_tiers WHERE quota_id = p_quota_id)
     AND h.status = 'active' AND h.expires_at > now();

  SELECT COALESCE(SUM(v.max_uses - v.used_count), 0) INTO v_blocked
    FROM public.exos_vouchers v
   WHERE v.tier_id IN (SELECT tier_id FROM public.exos_quota_tiers WHERE quota_id = p_quota_id)
     AND v.block_quota AND v.used_count < v.max_uses
     AND (v.valid_until IS NULL OR v.valid_until > now());

  RETURN GREATEST(0, v_size - v_used - v_held - v_blocked);
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_quota_available(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_quota_available(uuid) TO anon, authenticated, service_role;

-- 3. Offers carry the waitlister's quantity and reserve it --------------------
CREATE OR REPLACE FUNCTION public._exos_waitlist_offer_core(
  p_event_id uuid, p_tier_id uuid, p_count integer, p_hours integer
) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_org   uuid; v_name text; v_count int := 0;
  v_seats int := greatest(1, least(500, coalesce(p_count,1)));   -- seats to offer
  v_hours int := greatest(1, coalesce(p_hours, 48));
  v_code  text; v_vid uuid; r record; v_safe text; v_qty int;
BEGIN
  SELECT org_id, name INTO v_org, v_name FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN RETURN 0; END IF;
  v_safe := replace(replace(coalesce(v_name,'an event'),'<','&lt;'),'>','&gt;');

  FOR r IN
    SELECT id, email, quantity FROM public.exos_waitlist
    WHERE event_id = p_event_id AND status = 'waiting'
      AND (p_tier_id IS NULL OR tier_id = p_tier_id OR tier_id IS NULL)
    ORDER BY created_at
    LIMIT 500
    FOR UPDATE SKIP LOCKED
  LOOP
    v_qty := greatest(1, coalesce(r.quantity, 1));
    -- FIFO: the next group waits for enough seats rather than being skipped.
    EXIT WHEN v_qty > v_seats;

    v_code := upper(encode(extensions.gen_random_bytes(6), 'hex'));
    INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,
                block_quota, reserved_email, valid_until, comment)
    VALUES (p_event_id, v_code, p_tier_id, v_qty, true, p_tier_id IS NOT NULL, r.email,
            now() + make_interval(hours => v_hours), 'waitlist auto-offer')
    RETURNING id INTO v_vid;

    UPDATE public.exos_waitlist
       SET status='offered', offered_at=now(),
           claim_expires_at = now() + make_interval(hours => v_hours), voucher_id = v_vid
     WHERE id = r.id;

    INSERT INTO public.exos_mail (template, to_email, subject, html, status)
    VALUES ('waitlist-open', r.email,
      left('A spot opened up: ' || left(coalesce(v_name,'your event'),120), 200),
      '<p>Good news — a spot just opened up for <strong>' || v_safe ||
        '</strong>.</p><p>Your code <strong>' || v_code || '</strong> lets you buy ' ||
        CASE WHEN v_qty > 1 THEN 'up to ' || v_qty::text || ' tickets' ELSE 'it' END ||
        ', but only for the next ' ||
        v_hours::text || ' hours — open the Bridge app and enter it at checkout before it rolls to the next person.</p>',
      'pending');
    v_count := v_count + 1;
    v_seats := v_seats - v_qty;
    EXIT WHEN v_seats <= 0;
  END LOOP;
  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public._exos_waitlist_offer_core(uuid, uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_waitlist_offer_core(uuid, uuid, integer, integer) TO service_role;

-- 4. Only offer seats that are really free ------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_waitlist_autooffer()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_freed int; v_avail int;
BEGIN
  IF NEW.capacity = 0 THEN RETURN NEW; END IF;       -- unlimited tier never offers
  v_freed := (NEW.capacity - NEW.sold) - (greatest(OLD.capacity,1) - OLD.sold);
  IF v_freed > 0 THEN
    -- Offer everything that is really free now (net of holds and outstanding
    -- offers — those already count as taken, so nothing is offered twice), not
    -- just this delta: seats freed one at a time must still add up to a group.
    -- 0 while the tier is still oversold.
    v_avail := coalesce(public.exos_effective_available(NEW.id), v_freed);
    v_freed := v_avail;
  END IF;
  IF v_freed > 0 THEN
    PERFORM 1 FROM public.exos_waitlist w
      WHERE w.event_id = NEW.event_id AND w.status = 'waiting'
        AND (w.tier_id = NEW.id OR w.tier_id IS NULL) LIMIT 1;
    IF FOUND THEN
      PERFORM public._exos_waitlist_offer_core(NEW.event_id, NEW.id, v_freed, 48);
    END IF;
  END IF;
  RETURN NEW;
END $$;
