-- ============================================================================
-- Migration 20260702121000 — Exos (Bridge / D4): close transferred-ticket
--                            barcode_secret leak
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  REPLACE exos_claim_transfer
-- Pre-reqs: 20260520130000 (tickets + exos_claim_transfer + exos_tickets_sel)
--
-- SECURITY FIX (audit 2026-07-02, HIGH). exos_claim_transfer rotates owner_id
-- and barcode_secret on claim but LEFT buyer_id pointing at the original buyer.
-- The exos_tickets_sel RLS policy grants a full-row read on `buyer_id =
-- auth.uid()`, so after a transfer the ORIGINAL buyer could still SELECT the
-- ticket and read the NEW owner's freshly-rotated barcode_secret — then compute
-- a fully valid signed barcode and walk in on the ticket they gave away. This
-- defeats the whole point of rotating the secret on transfer.
--
-- Fix: reassign buyer_id to the claimer (the new holder) on claim. The original
-- buyer then matches neither owner_id nor buyer_id and loses RLS read on the
-- row (and on exos_holds_ticket). Their purchase record is unaffected — receipts
-- live in exos_invoices / exos_checkout_sessions (own buyer_id, untouched here),
-- and the transfer history stays in exos_transfers (sender_id).
--
-- Only the UPDATE changed vs mig 20260520130000 (+ buyer_id = v_uid); the rest
-- of the body is byte-identical.
-- D4 authors; A1 applies to prod.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.exos_claim_transfer(p_transfer_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_email  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  tr       public.exos_transfers%ROWTYPE;
  v_status text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_claim_transfer: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_claim_transfer: email not verified';
  END IF;

  SELECT * INTO tr FROM public.exos_transfers WHERE id = p_transfer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer not found';
  END IF;
  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer is %', tr.status;
  END IF;
  IF v_email = '' OR lower(tr.receiver_email) <> v_email THEN
    RAISE EXCEPTION 'exos_claim_transfer: transfer addressed to a different email';
  END IF;

  SELECT status INTO v_status FROM public.exos_tickets WHERE id = tr.ticket_id;
  IF v_status = 'used' THEN
    RAISE EXCEPTION 'exos_claim_transfer: ticket already checked in';
  END IF;
  IF v_status = 'voided' THEN
    RAISE EXCEPTION 'exos_claim_transfer: ticket was refunded';
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

-- ROLLBACK: recreate exos_claim_transfer from mig 20260520130000 (drops the
-- buyer_id reassignment).
