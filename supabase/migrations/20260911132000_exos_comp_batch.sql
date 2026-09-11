-- ============================================================================
-- Migration 20260911132000 — Exos (Bridge / D4): bulk comp issuance + org comp budget
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_orgs (W: +comp_budget),
--           exos_tickets (W: INSERT comp tickets), exos_ticket_tiers (W: sold),
--           exos_events (W: tickets_sold), exos_transfers (W: INSERT pending
--           claim-by-email rows for recipients without an account),
--           exos_mail (W: INSERT ticket-issued / transfer-initiated),
--           auth.users (R),
--           exos_org_comp_usage(uuid) (new, staff read),
--           exos_set_org_comp_budget(uuid, int) (new, owner/admin),
--           exos_issue_comp_batch(uuid, uuid, text[], int, text) (new, owner/manager)
-- Pre-reqs: 20260523230000 (exos_issue_ticket_to_email — the single-recipient
--           path this generalises), 20260520130000 (exos_transfers shape),
--           20260520160000 (exos_mail + 'transfer-initiated' / 'ticket-issued')
--
-- Stage 3 "group sales / comp allocations". exos_issue_ticket_to_email issues
-- ONE named comp and requires the recipient to already have an account. Guest
-- lists are pasted as 20-200 emails, half of whom have never signed up. This
-- adds:
--
--   * exos_issue_comp_batch(event, tier, emails[], qty_each, promoter)
--       - one call, one result row per DISTINCT valid email:
--           outcome 'issued'        recipient has an account → tickets minted to
--                                   them + 'ticket-issued' mail
--           outcome 'invited'       no account → tickets minted to the CALLER
--                                   with a pending transfer to the email +
--                                   'transfer-initiated' mail (they claim by
--                                   email on sign-up: the existing path)
--           outcome 'sold-out'      tier / house cap exhausted for this row
--           outcome 'invalid'       not an email
--       - capacity is claimed per row (never over-issues); the per-account
--         purchase limit is BYPASSED (staff decision, as in issue_to_email)
--       - channel_source = 'comp', price 0, order_ref 'comp:<batch uuid>'
--   * Per-org comp budget: exos_orgs.comp_budget (NULL = unlimited). Usage =
--     non-voided FREE tickets issued through the staff comp paths
--     (channel_source 'comp' or 'boxoffice'). A batch that would exceed the
--     budget is refused WHOLE, before any row is issued (predictable for the
--     organizer; no half-issued lists). The org row is locked for the check.
--
-- Harness parity: the transfer row is built with jsonb_populate_record so the
-- prod-only denormalised columns (sender_email, event_title, …) are filled in
-- prod and simply ignored where the table is narrower.
--
-- ROLLBACK: DROP FUNCTION exos_issue_comp_batch(uuid,uuid,text[],int,text),
--   exos_set_org_comp_budget(uuid,int), exos_org_comp_usage(uuid);
--   ALTER TABLE exos_orgs DROP COLUMN comp_budget;
-- ============================================================================

ALTER TABLE public.exos_orgs
  ADD COLUMN IF NOT EXISTS comp_budget integer CHECK (comp_budget IS NULL OR comp_budget >= 0);
COMMENT ON COLUMN public.exos_orgs.comp_budget IS
  'Max non-voided free comp tickets the org may issue via the staff comp paths (NULL = unlimited). Checked by exos_issue_comp_batch.';

-- ---------------------------------------------------------------------------
-- 1. Usage (staff read).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_org_comp_usage(p_org_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_org_comp_usage: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(p_org_id, ARRAY['owner','manager','finance'])) THEN
    RAISE EXCEPTION 'exos_org_comp_usage: not authorized' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO v_n
    FROM public.exos_tickets
   WHERE org_id = p_org_id
     AND channel_source IN ('comp','boxoffice')
     AND coalesce(price_paid, 0) = 0
     AND status <> 'voided';
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_org_comp_usage(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_org_comp_usage(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Budget setter (owner / admin). NULL clears the cap.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_org_comp_budget(p_org_id uuid, p_budget int DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_set_org_comp_budget: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(p_org_id, ARRAY['owner'])) THEN
    RAISE EXCEPTION 'exos_set_org_comp_budget: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_budget IS NOT NULL AND (p_budget < 0 OR p_budget > 1000000) THEN
    RAISE EXCEPTION 'exos_set_org_comp_budget: budget must be 0..1000000 or NULL';
  END IF;
  UPDATE public.exos_orgs SET comp_budget = p_budget WHERE id = p_org_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_set_org_comp_budget: org not found';
  END IF;
  RETURN p_budget;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_org_comp_budget(uuid, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_org_comp_budget(uuid, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. The batch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_issue_comp_batch(
  p_event_id    uuid,
  p_tier_id     uuid    DEFAULT NULL,
  p_emails      text[]  DEFAULT '{}',
  p_qty_each    int     DEFAULT 1,
  p_promoter_id text    DEFAULT NULL
) RETURNS TABLE (email text, outcome text, ticket_ids uuid[], detail text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_uid_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_ev        public.exos_events%ROWTYPE;
  v_org       public.exos_orgs%ROWTYPE;
  v_tier_name text;
  v_tier_ev   uuid;
  v_batch     text := 'comp:' || gen_random_uuid()::text;
  v_safe      text;
  v_valid     text[] := '{}';
  v_invalid   text[] := '{}';
  v_self      text[] := '{}';
  v_seen      text[] := '{}';
  v_raw       text;
  v_e         text;
  v_usage     int;
  v_need      int;
  v_rcpt      uuid;
  v_owner     uuid;
  v_ids       uuid[];
  v_id        uuid;
  v_tr        uuid;
  v_updated   int;
  i           int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_qty_each < 1 OR p_qty_each > 10 THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: quantity per recipient must be 1-10';
  END IF;
  IF coalesce(array_length(p_emails, 1), 0) = 0 THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: no recipients';
  END IF;
  IF array_length(p_emails, 1) > 200 THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: max 200 recipients per batch';
  END IF;

  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_ev.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_ev.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_issue_comp_batch: event is cancelled';
  END IF;
  IF p_tier_id IS NOT NULL THEN
    SELECT name, event_id INTO v_tier_name, v_tier_ev FROM public.exos_ticket_tiers WHERE id = p_tier_id;
    IF v_tier_ev IS NULL OR v_tier_ev <> p_event_id THEN
      RAISE EXCEPTION 'exos_issue_comp_batch: tier not found for this event';
    END IF;
  END IF;

  -- Normalise + dedupe + validate.
  FOREACH v_raw IN ARRAY p_emails LOOP
    v_e := lower(btrim(coalesce(v_raw, '')));
    IF v_e = '' THEN CONTINUE; END IF;
    IF v_e = ANY (v_seen) THEN CONTINUE; END IF;
    v_seen := array_append(v_seen, v_e);
    IF v_e = v_uid_email THEN
      v_self := array_append(v_self, v_e);
    ELSIF length(v_e) > 320 OR v_e !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN
      v_invalid := array_append(v_invalid, v_e);
    ELSE
      v_valid := array_append(v_valid, v_e);
    END IF;
  END LOOP;

  -- Budget gate (whole batch), under a row lock on the org.
  SELECT * INTO v_org FROM public.exos_orgs WHERE id = v_ev.org_id FOR UPDATE;
  IF v_org.comp_budget IS NOT NULL THEN
    SELECT count(*) INTO v_usage FROM public.exos_tickets
     WHERE org_id = v_ev.org_id AND channel_source IN ('comp','boxoffice')
       AND coalesce(price_paid, 0) = 0 AND status <> 'voided';
    v_need := coalesce(array_length(v_valid, 1), 0) * p_qty_each;
    IF v_usage + v_need > v_org.comp_budget THEN
      RAISE EXCEPTION 'exos_issue_comp_batch: comp budget exceeded — % of % used, this batch needs % more',
        v_usage, v_org.comp_budget, v_need USING ERRCODE = '23514';
    END IF;
  END IF;

  v_safe := replace(replace(coalesce(v_ev.name, 'your event'), '<', '&lt;'), '>', '&gt;');

  FOREACH v_e IN ARRAY v_invalid LOOP
    email := v_e; outcome := 'invalid'; ticket_ids := '{}'; detail := 'not a valid recipient email';
    RETURN NEXT;
  END LOOP;
  FOREACH v_e IN ARRAY v_self LOOP
    email := v_e; outcome := 'invalid'; ticket_ids := '{}'; detail := 'you cannot comp yourself — use the box-office mint';
    RETURN NEXT;
  END LOOP;

  FOREACH v_e IN ARRAY v_valid LOOP
    email := v_e; ticket_ids := '{}'; detail := NULL; v_ids := '{}';

    -- Capacity claim for this recipient: HOUSE CAP FIRST, then the tier. The
    -- order matters — exos_ticket_tiers.sold carries the waitlist auto-offer
    -- trigger (AFTER UPDATE OF sold), so an undo on the TIER would mint bypass
    -- vouchers for capacity that was never freed. exos_events.tickets_sold has
    -- no trigger, so it is the safe one to undo. A miss leaves earlier rows
    -- issued and reports 'sold-out' for this row.
    UPDATE public.exos_events
       SET tickets_sold = tickets_sold + p_qty_each
     WHERE id = p_event_id
       AND (total_tickets = 0 OR tickets_sold + p_qty_each <= total_tickets);
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
      outcome := 'sold-out'; detail := 'event capacity reached'; RETURN NEXT; CONTINUE;
    END IF;
    IF p_tier_id IS NOT NULL THEN
      UPDATE public.exos_ticket_tiers
         SET sold = sold + p_qty_each
       WHERE id = p_tier_id
         AND (capacity = 0 OR sold + p_qty_each <= capacity);
      GET DIAGNOSTICS v_updated = ROW_COUNT;
      IF v_updated = 0 THEN
        -- Undo the house-cap claim (trigger-free counter).
        UPDATE public.exos_events SET tickets_sold = greatest(tickets_sold - p_qty_each, 0) WHERE id = p_event_id;
        outcome := 'sold-out'; detail := 'tier capacity reached'; RETURN NEXT; CONTINUE;
      END IF;
    END IF;

    SELECT u.id INTO v_rcpt FROM auth.users u WHERE lower(u.email) = v_e LIMIT 1;
    v_owner := coalesce(v_rcpt, v_uid);

    FOR i IN 1..p_qty_each LOOP
      INSERT INTO public.exos_tickets (
        event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
        status, barcode_secret, price_paid, order_ref, channel_source, promoter_id
      ) VALUES (
        p_event_id, v_ev.org_id, p_tier_id, v_tier_name, v_owner, v_owner, v_e,
        'active', gen_random_uuid()::text, 0, v_batch, 'comp', nullif(p_promoter_id, '')
      ) RETURNING id INTO v_id;
      v_ids := array_append(v_ids, v_id);

      IF v_rcpt IS NULL THEN
        -- No account: park the ticket on the caller with a pending transfer the
        -- recipient claims by email (existing exos_claim_transfer path).
        INSERT INTO public.exos_transfers
        SELECT * FROM jsonb_populate_record(NULL::public.exos_transfers, jsonb_build_object(
          'id', gen_random_uuid(), 'ticket_id', v_id, 'org_id', v_ev.org_id,
          'sender_id', v_uid, 'sender_email', nullif(v_uid_email, ''), 'receiver_email', v_e,
          'status', 'pending', 'event_id', p_event_id, 'event_title', v_ev.name,
          'event_image', v_ev.image_url, 'tier_name', v_tier_name, 'organizer_id', v_ev.created_by,
          -- jsonb_populate_record yields NULL (not DEFAULT) for absent keys —
          -- every NOT NULL DEFAULT column must be set here (§3 landmine).
          'created_at', now(), 'updated_at', now()))
        RETURNING id INTO v_tr;
        UPDATE public.exos_tickets
           SET pending_transfer_id = v_tr, last_reissue_at = now()
         WHERE id = v_id;
      END IF;
    END LOOP;

    -- One mail per recipient (server-derived; never a client-supplied body).
    IF v_rcpt IS NOT NULL THEN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES ('ticket-issued', v_e,
              left('Your ticket' || CASE WHEN p_qty_each > 1 THEN 's' ELSE '' END || ' for ' || v_safe || ' ' ||
                   CASE WHEN p_qty_each > 1 THEN 'are' ELSE 'is' END || ' ready', 200),
              '<p>You''ve been issued ' || p_qty_each || ' complimentary ticket' ||
              CASE WHEN p_qty_each > 1 THEN 's' ELSE '' END || ' for <strong>' || v_safe ||
              '</strong>. Open the app to show your QR at the door.</p>', v_uid, 'pending');
      outcome := 'issued';
    ELSE
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES ('transfer-initiated', v_e,
              left('You''ve been sent a ticket for ' || v_safe, 200),
              '<p>The organizer of <strong>' || v_safe || '</strong> sent you ' || p_qty_each ||
              ' complimentary ticket' || CASE WHEN p_qty_each > 1 THEN 's' ELSE '' END ||
              '. Sign in to the Bridge app with this email address to claim ' ||
              CASE WHEN p_qty_each > 1 THEN 'them' ELSE 'it' END || '.</p>', v_uid, 'pending');
      outcome := 'invited'; detail := 'no account yet — claim-by-email transfer created';
    END IF;
    ticket_ids := v_ids;
    RETURN NEXT;
  END LOOP;
  RETURN;
END $$;
REVOKE ALL ON FUNCTION public.exos_issue_comp_batch(uuid, uuid, text[], int, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_issue_comp_batch(uuid, uuid, text[], int, text) TO authenticated;

COMMENT ON FUNCTION public.exos_issue_comp_batch(uuid, uuid, text[], int, text) IS
  'D4 mig 20260911132000: bulk comp issuance to an email list (owner/manager/admin). Account holders get tickets + ticket-issued mail; others get caller-held tickets with a pending claim-by-email transfer + transfer-initiated mail. Per-row capacity claim; whole-batch org comp_budget gate.';
