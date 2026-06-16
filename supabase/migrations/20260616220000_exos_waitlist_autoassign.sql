-- ============================================================================
-- Migration 20260616220000 — Exos (Bridge / D4): waitlist auto-assignment
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_waitlist (+offered status, +offered_at/claim_expires_at/
--           voucher_id), _exos_waitlist_offer_core / exos_waitlist_offer_next /
--           exos_waitlist_expire_offers (W,new), AFTER trigger on
--           exos_ticket_tiers, REPLACE exos_tg_consume_voucher; reads/writes
--           exos_vouchers, exos_mail, exos_events
-- Pre-reqs: 20260616180000 (waitlist), 20260616210000 (vouchers + consume trig)
--
-- pretix-style auto-assignment: when capacity frees up (a refund/void lowers
-- tier.sold, or the organizer raises capacity), the next person on the waitlist
-- is automatically OFFERED the spot — issued a single-use, email-reserved,
-- capacity-BYPASSING voucher (the existing voucher system) valid for a claim
-- window, and emailed the code. If they don't redeem within the window the
-- offer expires and the spot rolls to the next person (exos_waitlist_expire_
-- offers, cron-driven). Redeeming the voucher marks the waitlist row converted.
-- D4 authors; A1 applies to prod. The expiry sweep needs a cron (operator).
-- ============================================================================

-- 1. Extend the waitlist row with the offer lifecycle.
ALTER TABLE public.exos_waitlist DROP CONSTRAINT IF EXISTS exos_waitlist_status_check;
ALTER TABLE public.exos_waitlist ADD  CONSTRAINT exos_waitlist_status_check
  CHECK (status IN ('waiting','notified','offered','converted','expired','cancelled'));
ALTER TABLE public.exos_waitlist ADD COLUMN IF NOT EXISTS offered_at      timestamptz;
ALTER TABLE public.exos_waitlist ADD COLUMN IF NOT EXISTS claim_expires_at timestamptz;
ALTER TABLE public.exos_waitlist ADD COLUMN IF NOT EXISTS voucher_id      uuid;

-- ===========================================================================
-- 2. Core offer engine (INTERNAL — no auth gate; called by the staff wrapper,
--    the capacity-free trigger, and the expiry sweep). Offers the next p_count
--    waiting joiners for an event (optionally a tier): mint a reserved bypass
--    voucher each, flip to 'offered', and email the code + window.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_waitlist_offer_core(
  p_event_id uuid, p_tier_id uuid, p_count integer, p_hours integer
) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_org   uuid; v_name text; v_count int := 0; v_lim int := greatest(1, least(500, coalesce(p_count,1)));
  v_hours int := greatest(1, coalesce(p_hours, 48));
  v_code  text; v_vid uuid; r record; v_safe text;
BEGIN
  SELECT org_id, name INTO v_org, v_name FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN RETURN 0; END IF;
  v_safe := replace(replace(coalesce(v_name,'an event'),'<','&lt;'),'>','&gt;');

  FOR r IN
    SELECT id, email FROM public.exos_waitlist
    WHERE event_id = p_event_id AND status = 'waiting'
      AND (p_tier_id IS NULL OR tier_id = p_tier_id OR tier_id IS NULL)
    ORDER BY created_at
    LIMIT v_lim
    FOR UPDATE SKIP LOCKED
  LOOP
    v_code := upper(encode(extensions.gen_random_bytes(6), 'hex'));
    INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,
                reserved_email, valid_until, comment)
    VALUES (p_event_id, v_code, p_tier_id, 1, true, r.email,
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
        '</strong>.</p><p>Your code <strong>' || v_code || '</strong> lets you buy it, but only for the next ' ||
        v_hours::text || ' hours — open the Bridge app and enter it at checkout before it rolls to the next person.</p>',
      'pending');
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public._exos_waitlist_offer_core(uuid, uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_waitlist_offer_core(uuid, uuid, integer, integer) TO service_role;

-- ===========================================================================
-- 3. Staff wrapper — organizer manually offers the next N (org-role gated).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_waitlist_offer_next(
  p_event_id uuid, p_count integer DEFAULT 1, p_hours integer DEFAULT 48, p_tier_id uuid DEFAULT NULL
) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN RAISE EXCEPTION 'exos_waitlist_offer_next: event not found'; END IF;
  IF v_uid IS NULL OR NOT exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_waitlist_offer_next: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_waitlist_offer_core(p_event_id, p_tier_id, p_count, p_hours);
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_waitlist_offer_next(uuid, integer, integer, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_waitlist_offer_next(uuid, integer, integer, uuid) TO authenticated;

-- ===========================================================================
-- 4. Auto-offer when a tier's available capacity rises (refund / void / cap
--    increase). Capacity 0 = unlimited → never sold out, never auto-offers.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_tg_waitlist_autooffer()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_freed int; v_org uuid;
BEGIN
  IF NEW.capacity = 0 THEN RETURN NEW; END IF;       -- unlimited tier never offers
  v_freed := (NEW.capacity - NEW.sold) - (greatest(OLD.capacity,1) - OLD.sold);
  IF v_freed > 0 THEN
    -- Only spend the effort if someone is actually waiting for this event/tier.
    PERFORM 1 FROM public.exos_waitlist w
      JOIN public.exos_events e ON e.id = w.event_id
      WHERE e.id = NEW.event_id AND w.status = 'waiting'
        AND (w.tier_id = NEW.id OR w.tier_id IS NULL) LIMIT 1;
    IF FOUND THEN
      PERFORM public._exos_waitlist_offer_core(NEW.event_id, NEW.id, v_freed, 48);
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS exos_tiers_waitlist_autooffer ON public.exos_ticket_tiers;
CREATE TRIGGER exos_tiers_waitlist_autooffer AFTER UPDATE OF sold, capacity ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_waitlist_autooffer();

-- ===========================================================================
-- 5. Redeeming the offered voucher converts the waitlist row. REPLACE the
--    consume trigger fn (from the vouchers migration) to also flip the row.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_tg_consume_voucher()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status = 'fulfilled' AND OLD.status IS DISTINCT FROM 'fulfilled'
     AND NEW.voucher_id IS NOT NULL THEN
    PERFORM public.exos_consume_voucher(NEW.voucher_id);
    UPDATE public.exos_waitlist SET status = 'converted'
      WHERE voucher_id = NEW.voucher_id AND status = 'offered';
  END IF;
  RETURN NEW;
END $$;

-- ===========================================================================
-- 6. Expiry sweep (cron) — expire stale offers, then roll each freed spot to
--    the next waiting person. Returns the number of offers expired.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_waitlist_expire_offers()
RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_n int := 0; r record;
BEGIN
  -- Expire and remember which (event, tier) slots reopened + how many.
  CREATE TEMP TABLE _expired ON COMMIT DROP AS
  SELECT w.event_id, v.tier_id, count(*) AS cnt
  FROM public.exos_waitlist w
  JOIN public.exos_vouchers v ON v.id = w.voucher_id
  WHERE w.status = 'offered' AND w.claim_expires_at < now()
  GROUP BY w.event_id, v.tier_id;

  UPDATE public.exos_waitlist SET status = 'expired'
   WHERE status = 'offered' AND claim_expires_at < now();
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- Roll each reopened slot to the next in line (the spot was never consumed).
  FOR r IN SELECT event_id, tier_id, cnt FROM _expired LOOP
    PERFORM public._exos_waitlist_offer_core(r.event_id, r.tier_id, r.cnt::int, 48);
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_waitlist_expire_offers() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_waitlist_expire_offers() TO service_role;

-- ===========================================================================
-- 7. Extend the staff summary with the new 'offered' bucket (return-type change
--    needs DROP + CREATE).
-- ===========================================================================
DROP FUNCTION IF EXISTS public.exos_waitlist_summary(uuid);
CREATE OR REPLACE FUNCTION public.exos_waitlist_summary(p_event_id uuid)
RETURNS TABLE (waiting integer, notified integer, offered integer, converted integer, total_quantity integer)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_org_id uuid;
BEGIN
  SELECT org_id INTO v_org_id FROM public.exos_events WHERE id = p_event_id;
  IF v_org_id IS NULL OR NOT exos_has_org_role(v_org_id, ARRAY['owner','manager','finance']) THEN
    RAISE EXCEPTION 'exos_waitlist_summary: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT
    count(*) FILTER (WHERE status = 'waiting')::int,
    count(*) FILTER (WHERE status = 'notified')::int,
    count(*) FILTER (WHERE status = 'offered')::int,
    count(*) FILTER (WHERE status = 'converted')::int,
    coalesce(sum(quantity) FILTER (WHERE status IN ('waiting','notified','offered')), 0)::int
  FROM public.exos_waitlist WHERE event_id = p_event_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_waitlist_summary(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_waitlist_summary(uuid) TO authenticated;

COMMENT ON FUNCTION public.exos_waitlist_offer_next(uuid, integer, integer, uuid) IS
  'D4 mig 20260616220000: pretix-style waitlist auto-assignment. Offers the next
   N waiting joiners a single-use, email-reserved, capacity-bypass voucher with a
   claim window; auto-fires on freed tier capacity; expiry sweep rolls to next.';
