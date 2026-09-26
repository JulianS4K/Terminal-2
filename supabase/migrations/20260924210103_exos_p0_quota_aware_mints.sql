-- ============================================================================
-- Migration 20260924210103 — Exos (Bridge / D4): P0 — every mint path respects
-- Already applied to prod via Supabase MCP on 2026-09-24 (operator-approved, Exos P0 + all-in; Terminal-2 #1003).
--                            shared quotas, live holds and waitlist offers
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_seats_available (new);
--              FUNCTIONS exos_claim_free_tickets, exos_issue_ticket_to_email,
--              exos_issue_comp_batch, exos_mint_tickets (patched in place)
--           R: exos_ticket_tiers, exos_quotas, exos_quota_tiers, exos_cart_holds, exos_vouchers
-- Pre-reqs: 20260702123030 (quotas + exos_effective_available), 20260924205508
--           (blocking vouchers in availability), and each patched function's
--           latest body: 20260605132500, 20260523230000, 20260911132000, 20260702123200
--
-- P0 (audit 2026-09-24, HIGH). Only checkout went through exos_effective_available.
-- The free-RSVP claim (callable by any signed-up user), staff issue-to-email,
-- bulk comps and the box-office mint checked `sold + qty <= capacity` and
-- nothing else, so they could oversell a shared quota and take seats already
-- reserved by someone's cart hold or waitlist offer — whose paid checkout then
-- failed at fulfillment and auto-refunded.
--
-- Fix: exos_seats_available(tier, qty) locks the tier's quotas and answers
-- "does effective availability (tier capacity net of live holds and blocking
-- offers, AND every shared quota) cover qty?". Each mint's existing capacity
-- claim gets `AND public.exos_seats_available(<tier>, <qty>)` in its WHERE, so
-- a refusal is the same zero-row UPDATE each function already handles (a raise
-- for the single claims, a per-recipient 'sold-out' row in the comp batch).
--
-- The four functions are patched from their live definitions (pg_get_functiondef)
-- rather than restated; each patch raises unless its pattern appears exactly once,
-- and is a no-op once applied. Idempotent. D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_seats_available(p_tier_id uuid, p_qty int)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_avail int;
BEGIN
  IF p_tier_id IS NULL THEN RETURN true; END IF;
  -- Serialize against other mints/holds drawing on the same shared pools.
  PERFORM 1 FROM public.exos_quotas q
    JOIN public.exos_quota_tiers qt ON qt.quota_id = q.id
   WHERE qt.tier_id = p_tier_id
   ORDER BY q.id
   FOR UPDATE OF q;
  v_avail := public.exos_effective_available(p_tier_id);
  RETURN v_avail IS NULL OR v_avail >= coalesce(p_qty, 1);
END $$;
REVOKE ALL ON FUNCTION public.exos_seats_available(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_seats_available(uuid, int) TO service_role;

DO $$
DECLARE
  p     record;
  v_def text;
  v_new text;
  v_hits int;
BEGIN
  FOR p IN
    SELECT * FROM (VALUES
      ('public.exos_claim_free_tickets',    'sold + p_quantity <= capacity)', 'p_tier_id', 'p_quantity'),
      ('public.exos_issue_ticket_to_email', 'sold + p_qty <= capacity)',      'p_tier_id', 'p_qty'),
      ('public.exos_issue_comp_batch',      'sold + p_qty_each <= capacity)', 'p_tier_id', 'p_qty_each'),
      ('public.exos_mint_tickets',          'sold + p_quantity <= capacity)', 'p_tier_id', 'p_quantity')
    ) AS t(fn, pat, tier_arg, qty_arg)
  LOOP
    IF (SELECT count(*) FROM pg_proc
         WHERE pronamespace = 'public'::regnamespace AND 'public.' || proname = p.fn) <> 1 THEN
      RAISE EXCEPTION 'quota-aware mints: expected exactly one % (missing or overloaded)', p.fn;
    END IF;
    SELECT pg_get_functiondef(o.oid) INTO v_def
      FROM pg_proc o
     WHERE o.pronamespace = 'public'::regnamespace AND 'public.' || o.proname = p.fn;
    v_new := p.pat || ' AND public.exos_seats_available(' || p.tier_arg || ', ' || p.qty_arg || ')';
    CONTINUE WHEN position(v_new in v_def) > 0;   -- already patched
    v_hits := (length(v_def) - length(replace(v_def, p.pat, ''))) / length(p.pat);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'quota-aware mints: expected one "%" in %, found %', p.pat, p.fn, v_hits;
    END IF;
    EXECUTE replace(v_def, p.pat, v_new);
  END LOOP;
END $$;
