-- ============================================================================
-- Migration 20260924200848 — Exos (Bridge / D4): audit 2026-09-24 hardening
--                            (quota mapping, transfer race, waitlist self-edit)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: POLICY exos_quotas_wr, POLICY exos_quota_tiers_wr (replaced);
--              FUNCTION exos_create_transfer, exos_claim_transfer (replaced);
--              POLICY exos_waitlist_upd (dropped), UPDATE grant on exos_waitlist (revoked)
--           R: exos_events, exos_ticket_tiers, exos_quotas, exos_tickets, exos_transfers
-- Pre-reqs: 20260702123030 (quotas), 20260520130000 (transfers), 20260616180000 (waitlist).
--           Supersedes the body of 20260702121000_exos_transfer_secret_leak_fix
--           (NOT applied to prod as of 2026-09-24) — its buyer_id fix is carried here.
--
-- 1. HIGH — cross-org quota mapping. exos_quota_tiers_wr only checked that the
--    caller manages the QUOTA's org, never the TIER's. Any user (open signup →
--    exos_create_org) could map a size-0 quota onto another org's tier (tier ids
--    are public via exos_public_tiers) and zero its availability, so every hold
--    and fulfillment for that tier failed. Now the tier must belong to the
--    quota's own event, and a quota's event must belong to its org.
--
-- 2. HIGH — transfer race. exos_create_transfer read the ticket without a lock,
--    so two concurrent calls both passed the "no pending transfer" check and
--    created two pending transfers; exos_claim_transfer never checked that the
--    ticket still pointed at THIS transfer or that the sender still owned it. A
--    seller could transfer to a buyer and to an alt account, let the buyer
--    claim, then claim the alt transfer and take the ticket back (rotating the
--    buyer's barcode). Both functions now lock the ticket row; create only sets
--    the pending pointer when it is still NULL; claim locks the transfer row and
--    requires ticket.pending_transfer_id = this transfer AND owner = sender;
--    a stale sibling transfer now fails to claim.
--    Also carries the unapplied 20260702121000 leak fix (buyer_id → claimer).
--
-- 3. MEDIUM — waitlist self-edit. exos_waitlist_upd + a table-wide UPDATE grant
--    let a user rewrite any column of their own row (created_at = queue
--    position, status, quantity, voucher_id). Every legitimate write goes
--    through SECURITY DEFINER RPCs (exos_leave_waitlist, exos_waitlist_offer_next,
--    auto-assign trigger); the client never UPDATEs the table directly.
--
-- Idempotent: DROP POLICY IF EXISTS + CREATE, CREATE OR REPLACE FUNCTION, REVOKE.
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- 1. Quota mapping must stay inside one org + one event -----------------------
DROP POLICY IF EXISTS exos_quotas_wr ON public.exos_quotas;
CREATE POLICY exos_quotas_wr ON public.exos_quotas FOR ALL TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager']))
  WITH CHECK (
    exos_has_org_role(org_id, ARRAY['owner','manager'])
    AND EXISTS (SELECT 1 FROM public.exos_events e
                WHERE e.id = event_id AND e.org_id = exos_quotas.org_id)
  );

DROP POLICY IF EXISTS exos_quota_tiers_wr ON public.exos_quota_tiers;
CREATE POLICY exos_quota_tiers_wr ON public.exos_quota_tiers FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_quotas q WHERE q.id = quota_id
                 AND exos_has_org_role(q.org_id, ARRAY['owner','manager'])))
  WITH CHECK (EXISTS (
    SELECT 1
      FROM public.exos_quotas q
      JOIN public.exos_ticket_tiers t ON t.id = exos_quota_tiers.tier_id
      JOIN public.exos_events e       ON e.id = t.event_id
     WHERE q.id = exos_quota_tiers.quota_id
       AND t.event_id = q.event_id
       AND e.org_id   = q.org_id
       AND exos_has_org_role(q.org_id, ARRAY['owner','manager'])
  ));

-- 2a. Create transfer: lock the ticket; only claim a NULL pending pointer ----
CREATE OR REPLACE FUNCTION public.exos_create_transfer(
  p_ticket_id      uuid,
  p_receiver_email text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_email       text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_recv        text := lower(btrim(coalesce(p_receiver_email, '')));
  t             public.exos_tickets%ROWTYPE;
  v_evt         public.exos_events%ROWTYPE;
  v_transfer_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_transfer: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF v_recv = '' OR position('@' in v_recv) = 0 THEN
    RAISE EXCEPTION 'exos_create_transfer: invalid receiver email';
  END IF;

  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_create_transfer: ticket not found';
  END IF;
  IF t.owner_id <> v_uid THEN
    RAISE EXCEPTION 'exos_create_transfer: not the ticket owner' USING ERRCODE = '42501';
  END IF;
  IF t.status <> 'active' THEN
    RAISE EXCEPTION 'exos_create_transfer: ticket is % (only active is transferable)', t.status;
  END IF;
  IF t.pending_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'exos_create_transfer: ticket already has a pending transfer';
  END IF;
  IF v_recv = v_email THEN
    RAISE EXCEPTION 'exos_create_transfer: cannot transfer a ticket to your own account';
  END IF;

  SELECT * INTO v_evt FROM public.exos_events WHERE id = t.event_id;
  IF v_evt.status = 'draft' THEN
    RAISE EXCEPTION 'exos_create_transfer: cannot transfer — event is still a draft';
  END IF;

  INSERT INTO public.exos_transfers (
    ticket_id, org_id, sender_id, sender_email, receiver_email, status,
    event_id, event_title, event_image, tier_name, organizer_id
  ) VALUES (
    p_ticket_id, t.org_id, v_uid, v_email, v_recv, 'pending',
    t.event_id, v_evt.name, v_evt.image_url, t.tier_name, v_evt.created_by
  ) RETURNING id INTO v_transfer_id;

  UPDATE public.exos_tickets
     SET pending_transfer_id = v_transfer_id, last_reissue_at = now()
   WHERE id = p_ticket_id AND pending_transfer_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_create_transfer: ticket already has a pending transfer';
  END IF;

  RETURN v_transfer_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_create_transfer(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_create_transfer(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_transfer(uuid, text) TO authenticated;

-- 2b. Claim transfer: lock both rows; the ticket must still point at this ----
--     transfer and still belong to its sender.
CREATE OR REPLACE FUNCTION public.exos_claim_transfer(p_transfer_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_email  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  tr       public.exos_transfers%ROWTYPE;
  t        public.exos_tickets%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_claim_transfer: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_claim_transfer: email not verified';
  END IF;

  SELECT * INTO tr FROM public.exos_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer not found';
  END IF;
  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer is %', tr.status;
  END IF;
  IF v_email = '' OR lower(tr.receiver_email) <> v_email THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer addressed to a different email';
  END IF;

  SELECT * INTO t FROM public.exos_tickets WHERE id = tr.ticket_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_claim_transfer: ticket not found';
  END IF;
  IF t.status = 'used' THEN
    RAISE EXCEPTION 'exos_claim_transfer: ticket already checked in';
  END IF;
  IF t.status = 'voided' THEN
    RAISE EXCEPTION 'exos_claim_transfer: ticket was refunded';
  END IF;
  IF t.pending_transfer_id IS DISTINCT FROM p_transfer_id OR t.owner_id <> tr.sender_id THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer is no longer valid for this ticket';
  END IF;

  UPDATE public.exos_transfers SET status = 'completed' WHERE id = p_transfer_id;

  -- Reassign BOTH owner_id and buyer_id to the claimer so the original buyer
  -- loses RLS read on the row (and thus on the rotated barcode_secret).
  UPDATE public.exos_tickets
     SET owner_id            = v_uid,
         buyer_id            = v_uid,
         status              = 'active',
         barcode_secret      = gen_random_uuid()::text,
         transfer_id         = p_transfer_id,
         pending_transfer_id = NULL,
         last_reissue_at     = now()
   WHERE id = tr.ticket_id;

  RETURN tr.ticket_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_claim_transfer(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_claim_transfer(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_claim_transfer(uuid) TO authenticated;

-- 3. Waitlist rows are written only through SECURITY DEFINER RPCs -------------
DROP POLICY IF EXISTS exos_waitlist_upd ON public.exos_waitlist;
REVOKE UPDATE ON public.exos_waitlist FROM authenticated;
