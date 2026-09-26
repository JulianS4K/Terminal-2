-- ============================================================================
-- Migration 20260925003000 — Exos (Bridge / D4): fixes from the 2026-09-25
--                            end-to-end trial run
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_fulfill_checkout, exos_refund_checkout,
--              exos_claim_free_tickets, exos_event_analytics (patched in place);
--              exos_create_hold (new optional p_voucher_code argument);
--              EXECUTE on exos_effective_available / exos_tier_available /
--              exos_seats_available (revoked from anon + authenticated)
-- Pre-reqs: 20260924215000 … 20260925001000 (the fulfill patches before it)
--
-- The trial ran the whole lifecycle on a local copy of prod's schema. Fixed here:
--
-- 1. A ticket's price_paid was the whole order total divided by the ticket
--    count, so add-ons were folded into every ticket (2 GA + a $10 poster
--    recorded $32.22 per ticket, not $27.22). That inflated promoter gross,
--    analytics and ticket.created webhooks. Now add-on money is taken out first.
-- 2. Refunds. A full refund of an order whose ticket was already scanned voided
--    nothing. Scanned tickets are now voided too; their seat stays taken,
--    because the person is inside. Analytics now also report add-on revenue,
--    partial refunds and net revenue.
-- 3. Free claims didn't require a confirmed email (holds and transfer claims
--    do), so bots could drain a free tier.
-- 4. A hidden tier could be held without its voucher, and anyone could read
--    hidden-tier stock through exos_effective_available. A hold on a hidden
--    tier now needs a valid voucher restricted to it. The availability helpers
--    are only called from other SECURITY DEFINER functions, so clients lose
--    direct EXECUTE.
--
-- Every patch asserts exactly one match and is skipped once applied, so the
-- file is safe to re-run. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- 1. price_paid excludes add-ons ------------------------------------------------
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.exos_fulfill_checkout(text)'::regprocedure);
  v_old text := 'round((s.amount_cents::numeric / 100) / s.quantity, 2),';
  v_new text := 'round(greatest(s.amount_cents - coalesce((SELECT sum(coalesce((a->>''quantity'')::int, 0) * coalesce((a->>''unit_price_cents'')::int, 0)) FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.addons) = ''array'' THEN s.addons ELSE ''[]''::jsonb END) a), 0), 0)::numeric / 100 / s.quantity, 2),';
BEGIN
  IF position('jsonb_array_elements(CASE WHEN jsonb_typeof(s.addons)' in v_def) > 0 THEN
    RAISE NOTICE 'exos_fulfill_checkout: add-on split already applied';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: expected exactly one price_paid expression';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- 2a. a full refund voids scanned tickets too -----------------------------------
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.exos_refund_checkout(text, text)'::regprocedure);
  v_old text := '  FOR r IN
    UPDATE public.exos_tickets
       SET status = ''voided'', voided_at = now(),';
  v_new text := '  -- Tickets checked in before the refund are voided as well, so they leave
  -- sold counts and revenue; their seat stays taken (the person is inside).
  UPDATE public.exos_tickets
     SET status = ''voided'', voided_at = now(),
         voided_reason = left(coalesce(p_reason, ''refunded''), 500)
   WHERE order_ref = p_session_id AND status = ''used'';

  FOR r IN
    UPDATE public.exos_tickets
       SET status = ''voided'', voided_at = now(),';
BEGIN
  IF position('checked in before the refund' in v_def) > 0 THEN
    RAISE NOTICE 'exos_refund_checkout: scanned-ticket void already applied';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'exos_refund_checkout: expected exactly one ticket void loop';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- 2b. analytics: add-on revenue, partial refunds, net revenue -------------------
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.exos_event_analytics(uuid)'::regprocedure);
  v_old text := '''revenue'',       v_revenue,';
  v_new text := '''revenue'',       v_revenue,
    ''addon_revenue'', (SELECT coalesce(sum(a.quantity * a.unit_price_paid), 0)
                        FROM public.exos_order_addons a
                       WHERE a.event_id = p_event_id AND a.status = ''active''),
    ''partial_refunds'', (SELECT round(coalesce(sum(rf.amount_cents), 0)::numeric / 100, 2)
                          FROM public.exos_order_refunds rf
                          JOIN public.exos_checkout_sessions cs ON cs.session_id = rf.session_id
                         WHERE cs.event_id = p_event_id AND rf.status = ''succeeded''
                           AND cs.status <> ''refunded''),
    ''net_revenue'', round(v_revenue
                   + (SELECT coalesce(sum(a.quantity * a.unit_price_paid), 0)
                        FROM public.exos_order_addons a
                       WHERE a.event_id = p_event_id AND a.status = ''active'')
                   - (SELECT coalesce(sum(rf.amount_cents), 0)::numeric / 100
                        FROM public.exos_order_refunds rf
                        JOIN public.exos_checkout_sessions cs ON cs.session_id = rf.session_id
                       WHERE cs.event_id = p_event_id AND rf.status = ''succeeded''
                         AND cs.status <> ''refunded''), 2),';
BEGIN
  IF position('''net_revenue''' in v_def) > 0 THEN
    RAISE NOTICE 'exos_event_analytics: net revenue already applied';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'exos_event_analytics: expected exactly one revenue key';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- 3. free claims need a confirmed email ------------------------------------------
DO $$
DECLARE
  v_def text := pg_get_functiondef(
    'public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text)'::regprocedure);
  v_old text := '    RAISE EXCEPTION ''exos_claim_free_tickets: not authenticated'' USING ERRCODE = ''42501'';
  END IF;';
  v_new text := '    RAISE EXCEPTION ''exos_claim_free_tickets: not authenticated'' USING ERRCODE = ''42501'';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION ''exos_claim_free_tickets: confirm your email before claiming tickets'' USING ERRCODE = ''42501'';
  END IF;';
BEGIN
  IF position('confirm your email before claiming tickets' in v_def) > 0 THEN
    RAISE NOTICE 'exos_claim_free_tickets: email gate already applied';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: expected exactly one auth check';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- 4a. a hold on a hidden tier needs its voucher ----------------------------------
DO $$
DECLARE
  v_def  text;
  v_sig  text := 'p_ttl_seconds integer DEFAULT 1800)';
  v_old  text := '  SELECT sales_start, sales_end INTO v_sstart, v_send
    FROM public.exos_ticket_tiers';
  v_new  text := '  SELECT sales_start, sales_end, visibility INTO v_sstart, v_send, v_vis
    FROM public.exos_ticket_tiers';
  v_chk_old text := '  IF v_sstart IS NOT NULL AND now() < v_sstart THEN
    RAISE EXCEPTION ''exos_create_hold: sales have not started';
  v_chk_new text := '  IF v_vis IS NOT NULL AND v_vis <> ''public'' AND NOT EXISTS (
       SELECT 1 FROM public.exos_check_voucher(p_event_id, p_voucher_code, NULLIF(v_email, '''')) v
        WHERE v.is_valid AND v.restrict_tier_id = p_tier_id) THEN
    RAISE EXCEPTION ''exos_create_hold: ticket type not available'' USING ERRCODE = ''42501'';
  END IF;
  IF v_sstart IS NOT NULL AND now() < v_sstart THEN
    RAISE EXCEPTION ''exos_create_hold: sales have not started';
BEGIN
  IF to_regprocedure('public.exos_create_hold(uuid, uuid, integer, integer, text)') IS NOT NULL THEN
    RAISE NOTICE 'exos_create_hold: voucher argument already applied';
    RETURN;
  END IF;
  v_def := pg_get_functiondef('public.exos_create_hold(uuid, uuid, integer, integer)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, v_sig, ''))) / length(v_sig) <> 1
     OR (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     OR (length(v_def) - length(replace(v_def, v_chk_old, ''))) / length(v_chk_old) <> 1 THEN
    RAISE EXCEPTION 'exos_create_hold: body not as expected';
  END IF;
  v_def := replace(v_def, v_sig, 'p_ttl_seconds integer DEFAULT 1800, p_voucher_code text DEFAULT NULL)');
  v_def := replace(v_def, '  q        record;', '  q        record;
  v_vis    text;');
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, v_chk_old, v_chk_new);
  DROP FUNCTION public.exos_create_hold(uuid, uuid, integer, integer);
  EXECUTE v_def;
END $$;
REVOKE ALL ON FUNCTION public.exos_create_hold(uuid, uuid, integer, integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_hold(uuid, uuid, integer, integer, text) TO authenticated, service_role;

-- 4b. stock helpers are internal -------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.exos_effective_available(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.exos_tier_available(uuid)      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.exos_seats_available(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_effective_available(uuid) TO service_role;
GRANT  EXECUTE ON FUNCTION public.exos_tier_available(uuid)      TO service_role;
GRANT  EXECUTE ON FUNCTION public.exos_seats_available(uuid, integer) TO service_role;
