-- ============================================================================
-- Migration 20260616210000 — Exos (Bridge / D4): vouchers (pretix parity)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_vouchers (W,new), exos_checkout_sessions (+voucher_id),
--           exos_check_voucher / exos_issue_voucher / exos_consume_voucher
--           (W,new RPCs) + AFTER trigger exos_tg_consume_voucher; reads
--           exos_events / exos_ticket_tiers / exos_has_org_role
-- Pre-reqs: 20260520120000 (events/tiers/has_org_role), 20260523170000
--           (checkout sessions), 20260616200000 (webhook trigger precedent),
--           pgcrypto (extensions.gen_random_bytes)
--
-- pretix-style VOUCHERS — deliberately DISTINCT from exos_discount_codes
-- (which is price-reduction-only and currently dormant). A voucher is an ACCESS
-- token, not a discount:
--   * bypass_capacity — let the holder buy a SOLD-OUT event/tier (the capacity
--     gate is skipped for a valid voucher). This is the capability discount
--     codes can't express.
--   * reserved_email — bind a voucher to ONE buyer (used by the waitlist
--     auto-assignment in the next migration: when a spot frees, the next person
--     in line is issued a single-use, reserved, capacity-bypassing voucher).
--   * price_override — optionally pin a price (comp / special rate).
--   * max_uses / used_count — single-use by default; consumed atomically on
--     successful fulfillment (a trigger, so the fulfillment fn isn't re-touched).
-- Codes are SECRET (org-staff CRUD only); the buyer validates a code via the
-- anon-callable exos_check_voucher (which never lists codes, only yes/no + the
-- grant it carries). Security mirrors phase-1 (deny-by-default RLS, SECDEF).
-- D4 authors; A1 applies to prod.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_vouchers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  code            text NOT NULL,
  -- NULL = valid for any tier; else restricted to this tier.
  tier_id         uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  max_uses        integer NOT NULL DEFAULT 1 CHECK (max_uses >= 1),
  used_count      integer NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  bypass_capacity boolean NOT NULL DEFAULT false,           -- buy past sold-out
  price_override  numeric CHECK (price_override IS NULL OR price_override >= 0),
  reserved_email  text CHECK (reserved_email IS NULL OR reserved_email = lower(reserved_email)),
  valid_until     timestamptz,
  comment         text,
  created_by      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, code)
);
CREATE INDEX IF NOT EXISTS exos_vouchers_event_idx ON public.exos_vouchers (event_id);

DROP TRIGGER IF EXISTS exos_vouchers_touch ON public.exos_vouchers;
CREATE TRIGGER exos_vouchers_touch BEFORE UPDATE ON public.exos_vouchers
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- Carry the redeemed voucher on the checkout session (edge fn writes; the
-- consume trigger reads it on fulfillment).
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS voucher_id uuid;

-- ===========================================================================
-- RLS — codes are secret; org staff manage. No public base-table read.
-- ===========================================================================
ALTER TABLE public.exos_vouchers ENABLE ROW LEVEL SECURITY;
CREATE POLICY exos_vouchers_all ON public.exos_vouchers FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager','finance'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])));
REVOKE ALL ON public.exos_vouchers FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON public.exos_vouchers TO authenticated;

-- ===========================================================================
-- exos_check_voucher — buyer-facing validation (anon-callable). Returns the
-- grant a valid code carries WITHOUT consuming it and WITHOUT exposing the code
-- list. Distinct output names (no column collisions — lesson from the waitlist
-- RETURNS TABLE bug).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_check_voucher(
  p_event_id uuid, p_code text, p_email text DEFAULT NULL
) RETURNS TABLE (is_valid boolean, voucher_id uuid, restrict_tier_id uuid,
                 can_bypass boolean, override_price numeric, reason text)
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE v public.exos_vouchers%ROWTYPE; v_email text := lower(btrim(coalesce(p_email,'')));
BEGIN
  SELECT * INTO v FROM public.exos_vouchers
   WHERE event_id = p_event_id AND code = btrim(p_code);
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, 'invalid code'; RETURN;
  END IF;
  IF v.valid_until IS NOT NULL AND v.valid_until < now() THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, 'expired'; RETURN;
  END IF;
  IF v.used_count >= v.max_uses THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, 'already used'; RETURN;
  END IF;
  IF v.reserved_email IS NOT NULL AND v.reserved_email <> v_email THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, NULL::boolean, NULL::numeric, 'reserved for another buyer'; RETURN;
  END IF;
  RETURN QUERY SELECT true, v.id, v.tier_id, v.bypass_capacity, v.price_override, NULL::text;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_check_voucher(uuid, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_check_voucher(uuid, text, text) TO anon, authenticated;

-- ===========================================================================
-- exos_issue_voucher — org staff (and the waitlist auto-assigner) mint a
-- voucher; returns the generated code. SECDEF + org-role gate.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_issue_voucher(
  p_event_id        uuid,
  p_tier_id         uuid    DEFAULT NULL,
  p_reserved_email  text    DEFAULT NULL,
  p_bypass_capacity boolean DEFAULT true,
  p_price_override  numeric DEFAULT NULL,
  p_max_uses        integer DEFAULT 1,
  p_valid_hours     integer DEFAULT NULL,
  p_comment         text    DEFAULT NULL
) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_org uuid; v_code text;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN RAISE EXCEPTION 'exos_issue_voucher: event not found'; END IF;
  IF v_uid IS NULL OR NOT exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_issue_voucher: not authorized' USING ERRCODE = '42501';
  END IF;
  v_code := upper(encode(extensions.gen_random_bytes(6), 'hex'));   -- 12-char code
  INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,
              price_override, reserved_email, valid_until, comment, created_by)
  VALUES (p_event_id, v_code, p_tier_id, greatest(1, coalesce(p_max_uses,1)), p_bypass_capacity,
          p_price_override, lower(nullif(btrim(p_reserved_email),'')),
          CASE WHEN p_valid_hours IS NOT NULL THEN now() + make_interval(hours => p_valid_hours) END,
          p_comment, v_uid);
  RETURN v_code;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_issue_voucher(uuid, uuid, text, boolean, numeric, integer, integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_issue_voucher(uuid, uuid, text, boolean, numeric, integer, integer, text) TO authenticated;

-- ===========================================================================
-- exos_consume_voucher — atomic single increment, refuses past max_uses.
-- service_role only (called by the consume trigger / fulfillment path).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_consume_voucher(p_voucher_id uuid)
RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE v_rows int;
BEGIN
  IF p_voucher_id IS NULL THEN RETURN false; END IF;
  UPDATE public.exos_vouchers
     SET used_count = used_count + 1
   WHERE id = p_voucher_id AND used_count < max_uses;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_consume_voucher(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_consume_voucher(uuid) TO service_role;

-- Consume the voucher exactly once, atomically, when a session is fulfilled.
-- A trigger (vs editing exos_fulfill_checkout) keeps the consume in the same
-- transaction as the status flip without re-touching the mint function.
CREATE OR REPLACE FUNCTION public.exos_tg_consume_voucher()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status = 'fulfilled' AND OLD.status IS DISTINCT FROM 'fulfilled'
     AND NEW.voucher_id IS NOT NULL THEN
    PERFORM public.exos_consume_voucher(NEW.voucher_id);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS exos_checkout_consume_voucher ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_consume_voucher AFTER UPDATE ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_consume_voucher();

COMMENT ON TABLE public.exos_vouchers IS
  'D4 mig 20260616210000: pretix-style ACCESS vouchers (distinct from the
   price-only exos_discount_codes). bypass_capacity = buy past sold-out;
   reserved_email = bind to one buyer (waitlist auto-assign); single-use by
   default, consumed atomically on fulfillment via exos_checkout_consume_voucher.';
