-- ============================================================================
-- Migration 20260925021000 — Exos (Bridge / D4): P1 database hardening from
--                            the 2026-09-24 audit
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: POLICY exos_orgs_sel_public (dropped), exos_orgs_public_read and
--              exos_events_public_read (anon only), exos_orgs_sel_member,
--              exos_events_sel_admin (new), exos_tiers_public_read (via helper);
--              VIEW exos_public_orgs / exos_public_events / exos_public_tiers
--              (no longer security_invoker);
--              FUNCTION exos_event_is_published, exos_comp_usage_count,
--              exos_assert_comp_budget (new); exos_org_comp_usage,
--              exos_issue_ticket_to_email (replaced); exos_check_in_ticket,
--              exos_fulfill_checkout, exos_issue_comp_batch, exos_mint_tickets,
--              exos_claim_free_tickets, exos_claim_invite (patched in place)
-- Pre-reqs: 20260925010000 (patch pattern), 20260925013000
--
-- EXP KANBAN "Audit 2026-09-24 — open findings", Database:
--  1. Any signed-in user could read every column of every org (owner_uid,
--     comp_budget) and of every published event (created_by, sync state,
--     distribution, test-window and reminder stamps). The base tables are now
--     readable by members (orgs), staff and ticket holders (events), and
--     platform admins; everyone else reads the column-narrowed exos_public_*
--     views, which now run as their owner so they keep returning every public
--     row. exos_tiers_public_read asks exos_event_is_published() instead of
--     reading exos_events as the caller. Anon is unchanged (column grants).
--  2. Check-in: the event is always checked (p_event_id NULL → wrong-event),
--     a cancelled event answers 'event-cancelled', anything that looks like a
--     barcode (T- prefix or ':' segments) must pass the HMAC check whatever the
--     source, and the logged verification is derived server-side ('verified'
--     only when the HMAC checked out, else 'manual'), never the client's word.
--  3. Fulfillment re-validates the session's voucher (still exists, reserved
--     email and tier still match, and it was not expired when checkout
--     started) before consuming it; a miss takes the all-or-nothing XF001
--     path (order failed, refund mail). Operator decision 2026-09-25: a
--     voucher that expires while the buyer is paying is honoured (the
--     30-minute Stripe session bounds the grace).
--  4. Comps: exos_issue_ticket_to_email no longer tells the caller whether an
--     email has an account (no account → claim-by-email transfer, like the
--     batch), and the batch reports 'issued' for both. The comp budget is now
--     enforced in every SECURITY DEFINER path that mints a free staff ticket
--     (issue-to-email and free box-office mints bypassed it); free mints are
--     recorded as 'boxoffice', and buyers can't label free claims as comps.
--     Invites: a claim never changes a membership edited after the invite was
--     sent and never demotes an owner; every invite expires (14 days when no
--     expiry is set, 30 days at most).
--
-- Deploy order: safe before or after the matching SPA change. With the
-- current bundle the only visible effect is the invite page showing
-- "an organization" instead of the org's name (it read exos_orgs as a
-- non-member); the SPA change reads exos_public_orgs there and knows the
-- 'event-cancelled' scan reason.
--
-- Every patch asserts one match and is skipped once applied (re-run safe).
-- D4 authors; applying to prod is operator-gated.
--
-- APPLIED to prod 2026-09-25 (operator-approved). Every function it creates or
-- patches was verified by md5 against a copy of prod's schema with it applied.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_sig text, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected one match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- 1. Org and event rows: members / staff / holders / admins only --------------

CREATE OR REPLACE FUNCTION public.exos_event_is_published(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND status = 'published') $$;
REVOKE ALL ON FUNCTION public.exos_event_is_published(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_event_is_published(uuid) TO anon, authenticated, service_role;

DROP POLICY IF EXISTS exos_orgs_sel_public ON public.exos_orgs;
DROP POLICY IF EXISTS exos_orgs_sel_member ON public.exos_orgs;
CREATE POLICY exos_orgs_sel_member ON public.exos_orgs FOR SELECT TO authenticated
  USING (public.exos_is_admin()
         OR public.exos_has_org_role(id, ARRAY['owner','manager','finance','scanner','content']));

DROP POLICY IF EXISTS exos_events_sel_admin ON public.exos_events;
CREATE POLICY exos_events_sel_admin ON public.exos_events FOR SELECT TO authenticated
  USING (status = 'published' AND public.exos_is_admin());

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'exos_orgs'
                AND policyname = 'exos_orgs_public_read') THEN
    ALTER POLICY exos_orgs_public_read ON public.exos_orgs TO anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'exos_events'
                AND policyname = 'exos_events_public_read') THEN
    ALTER POLICY exos_events_public_read ON public.exos_events TO anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'exos_ticket_tiers'
                AND policyname = 'exos_tiers_public_read') THEN
    ALTER POLICY exos_tiers_public_read ON public.exos_ticket_tiers
      USING (visibility = 'public' AND public.exos_event_is_published(event_id));
  END IF;
END $$;

-- The public views filter rows and columns themselves; run them as their
-- owner so a signed-in non-member still sees every public row.
ALTER VIEW IF EXISTS public.exos_public_orgs   SET (security_invoker = false, security_barrier = true);
ALTER VIEW IF EXISTS public.exos_public_events SET (security_invoker = false, security_barrier = true);
ALTER VIEW IF EXISTS public.exos_public_tiers  SET (security_invoker = false, security_barrier = true);

-- 2. Check-in hardening ---------------------------------------------------------

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid)',
  'v_verified  boolean',
  '  v_test      boolean := false;',
  '  v_test      boolean := false;
  v_verified  boolean := false;');

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid)',
  'p1: event scope required',
  $o$  IF p_event_id IS NOT NULL AND v_event <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;$o$,
  $n$  -- p1: event scope required (the scanner always works on one event)
  IF p_event_id IS NULL OR v_event <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = v_event AND e.status = 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'event-cancelled');
  END IF;$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid)',
  'p1: anything that looks like a barcode',
  $o$    v_signed boolean := (p_barcode_payload IS NOT NULL AND left(p_barcode_payload, 2) = 'T-');$o$,
  $n$    -- p1: anything that looks like a barcode (T- prefix or ':' segments) must
    -- verify, whatever the source; a bare ticket id typed by staff is manual.
    v_signed boolean := (nullif(btrim(p_barcode_payload), '') IS NOT NULL
                         AND (upper(left(btrim(p_barcode_payload), 2)) = 'T-'
                              OR position(':' in p_barcode_payload) > 0));$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid)',
  'v_verified := true',
  $o$        IF v_exp <> v_parts[4] THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;$o$,
  $n$        IF v_exp <> v_parts[4] THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'barcode-rejected');
        END IF;
        v_verified := true;$n$);

SELECT pg_temp.exos_patch('public.exos_check_in_ticket(uuid, text, text, text, uuid)',
  'CASE WHEN v_verified THEN',
  $o$    CASE WHEN p_source IN ('camera','manual') THEN p_source ELSE 'manual' END,
    CASE WHEN p_verification IN ('verified','legacy','manual') THEN p_verification ELSE 'manual' END$o$,
  $n$    CASE WHEN v_verified AND p_source = 'camera' THEN 'camera' ELSE 'manual' END,
    CASE WHEN v_verified THEN 'verified' ELSE 'manual' END$n$);

-- 3. Fulfillment re-validates the voucher ------------------------------------------

SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  'voucher no longer valid at fulfillment',
  $o$    IF s.voucher_id IS NOT NULL THEN
      SELECT bypass_capacity INTO v_bypass FROM public.exos_vouchers WHERE id = s.voucher_id;$o$,
  $n$    IF s.voucher_id IS NOT NULL THEN
      IF NOT EXISTS (
           SELECT 1 FROM public.exos_vouchers v
            WHERE v.id = s.voucher_id AND v.event_id = s.event_id
              AND (v.valid_until IS NULL OR v.valid_until >= coalesce(s.created_at, now()))
              AND (v.reserved_email IS NULL
                   OR lower(btrim(v.reserved_email)) = lower(btrim(coalesce(s.buyer_email, ''))))
              AND (v.tier_id IS NULL OR v.tier_id = s.tier_id)) THEN
        RAISE EXCEPTION 'voucher no longer valid at fulfillment' USING ERRCODE = 'XF001';
      END IF;
      SELECT bypass_capacity INTO v_bypass FROM public.exos_vouchers WHERE id = s.voucher_id;$n$);

-- The failure mail names the right cause when it was the voucher.
SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  'access code you used',
  $o$          '</strong> sold out while you were paying, so your order didn''t go through. ' ||$o$,
  $n$          CASE WHEN v_fail LIKE 'voucher%'
               THEN '</strong> couldn''t be issued because the access code you used is no longer valid, so your order didn''t go through. '
               ELSE '</strong> sold out while you were paying, so your order didn''t go through. ' END ||$n$);

-- 4a. Comp budget, enforced in every free staff mint -----------------------------

CREATE OR REPLACE FUNCTION public.exos_comp_usage_count(p_org_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT count(*)::int FROM public.exos_tickets
   WHERE org_id = p_org_id
     AND channel_source IN ('comp','boxoffice')
     AND coalesce(price_paid, 0) = 0
     AND status <> 'voided';
$$;
REVOKE ALL ON FUNCTION public.exos_comp_usage_count(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_comp_usage_count(uuid) TO service_role;

-- Locks the org row, so concurrent comp mints for one org serialize.
CREATE OR REPLACE FUNCTION public.exos_assert_comp_budget(p_org_id uuid, p_need integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_budget int; v_usage int;
BEGIN
  SELECT comp_budget INTO v_budget FROM public.exos_orgs WHERE id = p_org_id FOR UPDATE;
  IF v_budget IS NULL THEN RETURN; END IF;
  v_usage := public.exos_comp_usage_count(p_org_id);
  IF v_usage + coalesce(p_need, 0) > v_budget THEN
    RAISE EXCEPTION 'comp budget exceeded — % of % used, this needs % more',
      v_usage, v_budget, coalesce(p_need, 0) USING ERRCODE = '23514';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.exos_assert_comp_budget(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_assert_comp_budget(uuid, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_org_comp_usage(p_org_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_org_comp_usage: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(p_org_id, ARRAY['owner','manager','finance'])) THEN
    RAISE EXCEPTION 'exos_org_comp_usage: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN public.exos_comp_usage_count(p_org_id);
END $$;

SELECT pg_temp.exos_patch('public.exos_issue_comp_batch(uuid, uuid, text[], integer, text)',
  'exos_assert_comp_budget',
  $o$  SELECT * INTO v_org FROM public.exos_orgs WHERE id = v_ev.org_id FOR UPDATE;
  IF v_org.comp_budget IS NOT NULL THEN
    SELECT count(*) INTO v_usage FROM public.exos_tickets
     WHERE org_id = v_ev.org_id AND channel_source IN ('comp','boxoffice')
       AND coalesce(price_paid, 0) = 0 AND status <> 'voided';
    v_need := coalesce(array_length(v_valid, 1), 0) * p_qty_each;
    IF v_usage + v_need > v_org.comp_budget THEN
      RAISE EXCEPTION 'exos_issue_comp_batch: comp budget exceeded — % of % used, this batch needs % more',
        v_usage, v_org.comp_budget, v_need USING ERRCODE = '23514';
    END IF;
  END IF;$o$,
  $n$  PERFORM public.exos_assert_comp_budget(v_ev.org_id, coalesce(array_length(v_valid, 1), 0) * p_qty_each);$n$);

-- The batch no longer says which recipients have an account.
SELECT pg_temp.exos_patch('public.exos_issue_comp_batch(uuid, uuid, text[], integer, text)',
  'p1: same outcome',
  $o$      outcome := 'invited'; detail := 'no account yet — claim-by-email transfer created';$o$,
  $n$      outcome := 'issued'; detail := NULL;  -- p1: same outcome with or without an account$n$);

SELECT pg_temp.exos_patch('public.exos_mint_tickets(uuid, uuid, integer, text, numeric, text)',
  'p1: a free staff mint is a comp',
  $o$    RAISE EXCEPTION 'exos_mint_tickets: not authorized for this event' USING ERRCODE = '42501';
  END IF;$o$,
  $n$    RAISE EXCEPTION 'exos_mint_tickets: not authorized for this event' USING ERRCODE = '42501';
  END IF;

  -- p1: a free staff mint is a comp: it counts against the org's comp budget.
  IF coalesce(p_price_paid, 0) = 0 THEN
    PERFORM public.exos_assert_comp_budget(v_org, p_quantity);
  END IF;$n$);

SELECT pg_temp.exos_patch('public.exos_mint_tickets(uuid, uuid, integer, text, numeric, text)',
  'THEN ''boxoffice'' ELSE ''vibepass''',
  $o$      p_order_ref, 'vibepass', p_promoter_id$o$,
  $n$      p_order_ref, CASE WHEN coalesce(p_price_paid, 0) = 0 THEN 'boxoffice' ELSE 'vibepass' END, p_promoter_id$n$);

-- Buyers can't label their own free claims as comps (it would eat the budget).
SELECT pg_temp.exos_patch('public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text)',
  'IN (''comp'', ''boxoffice'') THEN ''vibepass''',
  $o$      coalesce(nullif(p_channel, ''), 'vibepass'), nullif(p_promoter_id, '')$o$,
  $n$      CASE WHEN lower(btrim(coalesce(p_channel, ''))) IN ('comp', 'boxoffice') THEN 'vibepass'
           ELSE coalesce(nullif(p_channel, ''), 'vibepass') END, nullif(p_promoter_id, '')$n$);

-- 4b. Issue-to-email: same answer with or without an account ----------------------

CREATE OR REPLACE FUNCTION public.exos_issue_ticket_to_email(
  p_event_id uuid, p_tier_id uuid DEFAULT NULL::uuid, p_recipient_email text DEFAULT NULL::text,
  p_qty integer DEFAULT 1, p_order_ref text DEFAULT NULL::text)
RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_uid_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_ev        public.exos_events%ROWTYPE;
  v_rcpt      uuid;
  v_owner     uuid;
  v_email     text;
  v_tier_name text;
  v_safe      text;
  v_ids       uuid[] := '{}';
  v_id        uuid;
  v_tr        uuid;
  v_updated   int;
  i           int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_qty < 1 OR p_qty > 10 THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: quantity must be 1-10';
  END IF;
  v_email := lower(btrim(coalesce(p_recipient_email, '')));
  IF v_email = '' OR position('@' in v_email) = 0 THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: invalid recipient email';
  END IF;

  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_ev.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: not authorized' USING ERRCODE = '42501';
  END IF;

  PERFORM public.exos_assert_comp_budget(v_ev.org_id, p_qty);

  -- Tier capacity claim (atomic). caps honored; per-account limit bypassed.
  IF p_tier_id IS NOT NULL THEN
    UPDATE public.exos_ticket_tiers
       SET sold = sold + p_qty
     WHERE id = p_tier_id AND event_id = p_event_id
       AND (capacity = 0 OR sold + p_qty <= capacity) AND public.exos_seats_available(p_tier_id, p_qty)
    RETURNING name INTO v_tier_name;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos_issue_ticket_to_email: tier sold out or not found for this event';
    END IF;
  END IF;

  UPDATE public.exos_events
     SET tickets_sold = tickets_sold + p_qty
   WHERE id = p_event_id
     AND (total_tickets = 0 OR tickets_sold + p_qty <= total_tickets);
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: event sold out — total_tickets cap reached' USING ERRCODE = '23514';
  END IF;

  -- No account: park the ticket on the caller with a claim-by-email transfer
  -- (the comp batch's path), so the answer is the same either way.
  SELECT id INTO v_rcpt FROM auth.users WHERE lower(email) = v_email LIMIT 1;
  v_owner := coalesce(v_rcpt, v_uid);

  FOR i IN 1..p_qty LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source
    ) VALUES (
      p_event_id, v_ev.org_id, p_tier_id, v_tier_name, v_owner, v_owner, v_email,
      'active', gen_random_uuid()::text, 0, coalesce(p_order_ref, 'boxoffice'), 'boxoffice'
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);

    IF v_rcpt IS NULL THEN
      -- jsonb_populate_record yields NULL (not DEFAULT) for absent keys, so every
      -- NOT NULL DEFAULT column is set here.
      INSERT INTO public.exos_transfers
      SELECT * FROM jsonb_populate_record(NULL::public.exos_transfers, jsonb_build_object(
        'id', gen_random_uuid(), 'ticket_id', v_id, 'org_id', v_ev.org_id,
        'sender_id', v_uid, 'sender_email', nullif(v_uid_email, ''), 'receiver_email', v_email,
        'status', 'pending', 'event_id', p_event_id, 'event_title', v_ev.name,
        'event_image', v_ev.image_url, 'tier_name', v_tier_name, 'organizer_id', v_ev.created_by,
        'created_at', now(), 'updated_at', now()))
      RETURNING id INTO v_tr;
      UPDATE public.exos_tickets
         SET pending_transfer_id = v_tr, last_reissue_at = now()
       WHERE id = v_id;
    END IF;
  END LOOP;

  v_safe := replace(replace(coalesce(v_ev.name, 'your event'), '<', '&lt;'), '>', '&gt;');
  IF v_rcpt IS NOT NULL THEN
    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES ('ticket-issued', v_email, left('Your ticket for ' || v_safe || ' is ready', 200),
            '<p>You''ve been issued a ticket for <strong>' || v_safe ||
            '</strong>. Open the app to show your QR at the door.</p>', v_uid, 'pending');
  ELSE
    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES ('transfer-initiated', v_email, left('You''ve been sent a ticket for ' || v_safe, 200),
            '<p>The organizer of <strong>' || v_safe || '</strong> sent you ' || p_qty ||
            ' ticket' || CASE WHEN p_qty > 1 THEN 's' ELSE '' END ||
            '. Sign in to Exos with this email address to claim ' ||
            CASE WHEN p_qty > 1 THEN 'them' ELSE 'it' END || '.</p>', v_uid, 'pending');
  END IF;

  RETURN v_ids;
END $$;

-- 4c. Stale invites ------------------------------------------------------------------

SELECT pg_temp.exos_patch('public.exos_claim_invite(uuid)',
  'p1: every invite expires',
  $o$  IF v_inv.expires_at IS NOT NULL AND v_inv.expires_at < now() THEN$o$,
  $n$  -- p1: every invite expires (14 days when none was set, 30 days at most).
  IF least(coalesce(v_inv.expires_at, v_inv.created_at + interval '14 days'),
           v_inv.created_at + interval '30 days') < now() THEN$n$);

SELECT pg_temp.exos_patch('public.exos_claim_invite(uuid)',
  'p1: a stale invite',
  $o$  ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role, disabled = false;$o$,
  $n$  ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role, disabled = false
    -- p1: a stale invite never changes a membership edited after it was sent,
    -- and an invite never demotes an owner.
    WHERE exos_org_memberships.role <> 'owner'
      AND exos_org_memberships.updated_at < v_inv.created_at;$n$);
