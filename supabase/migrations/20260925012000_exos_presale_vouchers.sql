-- ============================================================================
-- Migration 20260925012000 — Exos (Bridge / D4): organizers can set up a
--                            presale (hidden tier + a code they choose)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_issue_voucher (+p_code), exos_check_voucher
--              (case-insensitive match); INDEX exos_vouchers (event, upper(code))
-- Pre-reqs: 20260616210000 (vouchers), 20260925003000 (hidden-tier holds need a voucher)
--
-- From the 2026-09-25 trial: a presale ("PRESALE-TEST unlocks the hidden
-- Presale tier") couldn't be set up from the organizer UI. The voucher editor
-- never sent a tier, and exos_issue_voucher only minted random codes, so the
-- trial renamed one with a direct UPDATE. Codes were also case-sensitive
-- ("presale-test" was refused).
--   * exos_issue_voucher takes an optional p_code (3-32 of [A-Za-z0-9_-]),
--     stored upper-case; a code already used on the event is refused.
--   * exos_check_voucher matches codes case-insensitively, and a unique index
--     on (event_id, upper(code)) keeps that unambiguous. Every code minted so
--     far is upper-case hex, so nothing changes for existing codes.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS exos_vouchers_event_code_ci_uq
  ON public.exos_vouchers (event_id, upper(code));

DO $$
DECLARE
  v_def text := pg_get_functiondef('public.exos_check_voucher(uuid, text, text)'::regprocedure);
  v_old text := 'WHERE event_id = p_event_id AND code = btrim(p_code);';
  v_new text := 'WHERE event_id = p_event_id AND upper(code) = upper(btrim(p_code));';
BEGIN
  IF position(v_new in v_def) > 0 THEN RETURN; END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'exos_check_voucher: expected one code match';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

DROP FUNCTION IF EXISTS public.exos_issue_voucher(uuid, uuid, text, boolean, numeric, integer, integer, text);
CREATE OR REPLACE FUNCTION public.exos_issue_voucher(
  p_event_id uuid, p_tier_id uuid DEFAULT NULL, p_reserved_email text DEFAULT NULL,
  p_bypass_capacity boolean DEFAULT true, p_price_override numeric DEFAULT NULL,
  p_max_uses integer DEFAULT 1, p_valid_hours integer DEFAULT NULL, p_comment text DEFAULT NULL,
  p_code text DEFAULT NULL
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
  IF p_tier_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_ticket_tiers WHERE id = p_tier_id AND event_id = p_event_id) THEN
    RAISE EXCEPTION 'exos_issue_voucher: ticket type is not on this event';
  END IF;
  IF nullif(btrim(p_code), '') IS NOT NULL THEN
    v_code := upper(btrim(p_code));
    IF v_code !~ '^[A-Z0-9_-]{3,32}$' THEN
      RAISE EXCEPTION 'exos_issue_voucher: codes are 3-32 letters, numbers, - or _' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.exos_vouchers WHERE event_id = p_event_id AND upper(code) = v_code) THEN
      RAISE EXCEPTION 'exos_issue_voucher: code % is already used on this event', v_code USING ERRCODE = '23505';
    END IF;
  ELSE
    v_code := upper(encode(extensions.gen_random_bytes(6), 'hex'));   -- 12-char code
  END IF;
  INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,
              price_override, reserved_email, valid_until, comment, created_by)
  VALUES (p_event_id, v_code, p_tier_id, greatest(1, coalesce(p_max_uses,1)), p_bypass_capacity,
          p_price_override, lower(nullif(btrim(p_reserved_email),'')),
          CASE WHEN p_valid_hours IS NOT NULL THEN now() + make_interval(hours => p_valid_hours) END,
          p_comment, v_uid);
  RETURN v_code;
END $$;
REVOKE ALL ON FUNCTION public.exos_issue_voucher(uuid, uuid, text, boolean, numeric, integer, integer, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_issue_voucher(uuid, uuid, text, boolean, numeric, integer, integer, text, text) TO authenticated, service_role;
