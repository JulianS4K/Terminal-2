-- ============================================================================
-- Migration 20260523230000 — Exos (Bridge / D4): issue ticket to an attendee
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_issue_ticket_to_email() RPC (W, new)
-- Pre-reqs: 20260520130000 (exos_tickets), 20260523210000 (ticket-issued mail)
--
-- Free-first issuance to a NAMED attendee (door/box-office comp + presale).
-- exos_mint_tickets mints to the caller (staff/self); this mints to a resolved
-- recipient account + emails them. Honors tier capacity + event total_tickets
-- caps; per-account purchase limit is intentionally BYPASSED (staff issuance is
-- a deliberate decision, like the admin path). v1 requires the recipient to
-- already have an account — non-account walk-ups use mint→transfer (claim by
-- email). Org owner/manager (or admin) only.
--
-- D4 authors; A1 applies.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_issue_ticket_to_email(
  p_event_id        uuid,
  p_tier_id         uuid DEFAULT NULL,
  p_recipient_email text DEFAULT NULL,
  p_qty             int  DEFAULT 1,
  p_order_ref       text DEFAULT NULL
) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_org       uuid;
  v_rcpt      uuid;
  v_email     text;
  v_tier_name text;
  v_evname    text;
  v_safe      text;
  v_ids       uuid[] := '{}';
  v_id        uuid;
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

  SELECT org_id, name INTO v_org, v_evname FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_rcpt FROM auth.users WHERE lower(email) = v_email;
  IF v_rcpt IS NULL THEN
    RAISE EXCEPTION 'exos_issue_ticket_to_email: recipient has no account — have them sign up, or use mint + transfer';
  END IF;

  -- Tier capacity claim (atomic). caps honored; per-account limit bypassed.
  IF p_tier_id IS NOT NULL THEN
    UPDATE public.exos_ticket_tiers
       SET sold = sold + p_qty
     WHERE id = p_tier_id AND event_id = p_event_id
       AND (capacity = 0 OR sold + p_qty <= capacity)
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

  FOR i IN 1..p_qty LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source
    ) VALUES (
      p_event_id, v_org, p_tier_id, v_tier_name, v_rcpt, v_rcpt, v_email,
      'active', gen_random_uuid()::text, 0, coalesce(p_order_ref, 'boxoffice'), 'boxoffice'
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  -- Notify the recipient (server-derived; reuses the ticket-issued template).
  v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');
  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES ('ticket-issued', v_email, left('Your ticket for ' || v_safe || ' is ready', 200),
          '<p>You''ve been issued a ticket for <strong>' || v_safe ||
          '</strong>. Open the app to show your QR at the door.</p>', v_uid, 'pending');

  RETURN v_ids;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_issue_ticket_to_email(uuid, uuid, text, int, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_issue_ticket_to_email(uuid, uuid, text, int, text) TO authenticated;
