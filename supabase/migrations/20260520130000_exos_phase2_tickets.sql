-- ============================================================================
-- Migration 20260520130000 — Exos (Bridge / D4) phase-2 schema: tickets,
-- transfers, check-in + scan-reject audit logs, and the write-path RPCs.
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_tickets (W), exos_transfers (W), exos_event_checkins (W),
--           exos_scan_rejects (W); reads/updates exos_events + exos_ticket_tiers
--           (counters) from SECURITY DEFINER RPCs only.
-- Pre-reqs: 20260520120000 (phase-1: orgs + events + exos_has_org_role()).
--
-- Phase 2 completes the move of Exos ticketing off Firestore. Phase 1 put
-- orgs + events on Supabase; the ticket/transfer/scan machinery stayed on
-- Firestore, severing the lifecycle at purchase. This adds the missing tables
-- and the write paths.
--
-- SECURITY MODEL — mirrors d4_bridge/firestore.rules exactly:
--   * Reads: tickets readable by owner|buyer|org-staff; transfers by
--     sender|receiver-email|org-staff; audit logs by org-staff. RLS SELECT.
--   * Writes: all go through SECURITY DEFINER RPCs (no direct INSERT/UPDATE/
--     DELETE policy on tickets/transfers/checkins). The RPCs each re-derive
--     auth.uid() and gate internally — the Postgres analogue of the elaborate
--     allow-update branches in firestore.rules > match /tickets, /transfers.
--   * The RPCs additionally CLOSE the two "known gaps" the Firestore rules
--     called out and could not fix client-side:
--       - oversell under concurrency  → exos_mint_tickets does an atomic
--         `UPDATE ... WHERE sold + qty <= capacity` tier claim.
--       - double-scan race            → exos_check_in_ticket does an atomic
--         `UPDATE ... WHERE status = 'active'` so only one scan wins.
--   * scan_rejects is the one table with a direct INSERT policy — it is a
--     high-volume, non-security-critical audit trail written client-side
--     after a failed verify; gated on org-staff + rejected_by = auth.uid().
--
-- MINTING — real buyer fulfillment (Stripe Checkout + webhook) remains phase-2
-- product work and runs server-side under service_role (bypasses RLS), so it is
-- NOT exposed here. exos_mint_tickets is the COMP / TEST-mint path: org staff
-- (owner|manager) or platform admin can mint directly to events their org owns.
-- This is what makes the end-to-end ticket → wallet → door-scan flow testable
-- on Supabase without a payment processor (wired to EventDetails' admin-only
-- "TEST" button). It is NOT a free-ticket hole: you can only mint to your own
-- org's events.
--
-- ⚠ B1 review requested on the RLS + RPC model before prod apply (new ticketing
-- surface; charter §6.5). D4 authors; validate on a Supabase preview branch;
-- A1 applies to prod.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Platform-admin helper (app_metadata.admin — set server-side, unforgeable
-- from the client; the Supabase analogue of the Firebase `admin` custom claim
-- in firestore.rules > isAdmin()). Reads the JWT only, so no SECURITY DEFINER.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_is_admin()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((auth.jwt() -> 'app_metadata' ->> 'admin') = 'true', false);
$$;
REVOKE EXECUTE ON FUNCTION public.exos_is_admin() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_is_admin() FROM anon;  -- Supabase default grants anon=X; PUBLIC revoke doesn't cover it
GRANT  EXECUTE ON FUNCTION public.exos_is_admin() TO authenticated, service_role;

-- (exos_holds_ticket is defined in §5b, AFTER exos_tickets exists — a
-- LANGUAGE sql function validates its body references at CREATE time, so it
-- cannot be declared before the table it reads.)

-- ===========================================================================
-- 1. Tickets. Mirrors the Firestore `tickets` doc shape (src/types.ts Ticket).
--    pending_transfer_id / transfer_id are plain uuid (NOT FKs) to avoid a
--    circular dependency with exos_transfers and to match the Firestore model
--    (no referential integrity there either); they are managed solely by RPCs.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_tickets (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id            uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE, -- denormalized for staff RLS without a join
  tier_id             uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  tier_name           text,                                  -- snapshot at mint
  buyer_id            uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  owner_id            uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  buyer_email         text,                                  -- lowercased denormalized buyer email
  status              text NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','transferred','used','voided')),
  -- Per-ticket HMAC secret. Set at mint, rotated on transfer claim so the
  -- previous owner's screenshot can't be used by the new owner. NOT NULL —
  -- a ticket without a secret would fall through to the legacy unsigned
  -- barcode branch in the scanner and defeat the rotating-barcode design.
  barcode_secret      text NOT NULL,
  price_paid          numeric NOT NULL DEFAULT 0 CHECK (price_paid >= 0),
  order_ref           text,                                  -- stripe session id, or comp/test ref
  channel_source      text NOT NULL DEFAULT 'vibepass',
  promoter_id         text,
  -- In-flight transfer lock (plain uuid, no FK — see table comment).
  pending_transfer_id uuid,
  transfer_id         uuid,                                  -- last completed claim
  voided_at           timestamptz,
  voided_by           uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  voided_reason       text,
  check_in_at         timestamptz,
  last_reissue_at     timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_tickets_owner_idx       ON public.exos_tickets (owner_id);
CREATE INDEX IF NOT EXISTS exos_tickets_event_idx       ON public.exos_tickets (event_id);
CREATE INDEX IF NOT EXISTS exos_tickets_org_idx         ON public.exos_tickets (org_id);
CREATE INDEX IF NOT EXISTS exos_tickets_event_owner_idx ON public.exos_tickets (event_id, owner_id);
CREATE INDEX IF NOT EXISTS exos_tickets_order_idx       ON public.exos_tickets (order_ref);

-- ===========================================================================
-- 2. Transfers. Mirrors the Firestore `transfers` doc. Denormalised event/tier
--    fields let the receiver render the claim screen without reading the ticket
--    (which they cannot — they're not yet owner/buyer/staff).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_transfers (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id      uuid NOT NULL REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  org_id         uuid,                                       -- denormalized
  sender_id      uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  sender_email   text,                                       -- lowercased
  receiver_email text NOT NULL,                              -- lowercased; matched against JWT email at claim
  status         text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','completed','cancelled')),
  -- Denormalised display fields for the claim UI.
  event_id       uuid,
  event_title    text,
  event_image    text,
  tier_name      text,
  organizer_id   uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_transfers_sender_idx   ON public.exos_transfers (sender_id);
CREATE INDEX IF NOT EXISTS exos_transfers_receiver_idx ON public.exos_transfers (lower(receiver_email));
CREATE INDEX IF NOT EXISTS exos_transfers_ticket_idx   ON public.exos_transfers (ticket_id);
CREATE INDEX IF NOT EXISTS exos_transfers_status_idx   ON public.exos_transfers (status);

-- ===========================================================================
-- 3. Per-ticket check-in audit log (append-only). Mirrors Firestore
--    events/{id}/checkIns/{ticketId}. Written by exos_check_in_ticket only.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_event_checkins (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id     uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  ticket_id    uuid NOT NULL,
  org_id       uuid NOT NULL,
  scanned_by   uuid NOT NULL REFERENCES auth.users (id) ON DELETE SET NULL,
  source       text CHECK (source IN ('camera','manual')),
  verification text CHECK (verification IN ('verified','legacy','manual')),
  scanned_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_checkins_event_idx  ON public.exos_event_checkins (event_id);
CREATE INDEX IF NOT EXISTS exos_event_checkins_ticket_idx ON public.exos_event_checkins (ticket_id);

-- ===========================================================================
-- 4. Per-event scan REJECTION audit log (append-only). Mirrors Firestore
--    events/{id}/scanRejects/{id}. Written client-side after a failed verify,
--    so it has a direct INSERT policy (§6) — unlike check-ins, which are an
--    RPC side effect.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_scan_rejects (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id            uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id              uuid NOT NULL,
  rejected_by         uuid NOT NULL REFERENCES auth.users (id) ON DELETE SET NULL,
  reason              text NOT NULL CHECK (reason IN (
                        'wrong-event','voided','used','in-transfer',
                        'invalid-barcode','not-found','expired-code')),
  source              text NOT NULL CHECK (source IN ('camera','manual')),
  ticket_id_attempted text,           -- free text (barcode payload / typed id), capped in app
  wrong_event_id      uuid,
  wrong_event_title   text,
  reason_detail       text,
  rejected_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_scan_rejects_event_idx ON public.exos_scan_rejects (event_id);

-- ===========================================================================
-- 5. updated_at triggers (tickets + transfers; audit logs are append-only).
--    Reuses public.exos_touch_updated_at() from the phase-1 migration.
-- ===========================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_tickets','exos_transfers'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON public.%I
         FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
  END LOOP;
END $$;

-- ===========================================================================
-- 5b. Ticket-holder check. SECURITY DEFINER so the §6 event read policy can ask
--     "does the caller hold a ticket to this event?" without the policy's
--     subquery recursing through exos_tickets' own RLS. Mirrors firestore.rules,
--     where a cancelled/published event stays readable to its ticket holders.
--     MUST come after exos_tickets (§1) — a LANGUAGE sql body is validated at
--     CREATE time, so it can't be declared before the table it reads.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_holds_ticket(p_event_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_tickets t
    WHERE t.event_id = p_event_id
      AND (t.owner_id = auth.uid() OR t.buyer_id = auth.uid())
  );
$$;
REVOKE EXECUTE ON FUNCTION public.exos_holds_ticket(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_holds_ticket(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_holds_ticket(uuid) TO authenticated, service_role;

-- ===========================================================================
-- 6. Row-Level Security (deny-by-default; SELECT-only for clients — all
--    mutations route through the §7 RPCs, except scan_rejects INSERT).
-- ===========================================================================
ALTER TABLE public.exos_tickets         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_transfers       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_event_checkins  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_scan_rejects    ENABLE ROW LEVEL SECURITY;

-- tickets: owner, buyer, or any staff role of the owning org may read.
-- (firestore.rules tickets.get/list: ownerId|buyerId|organizerId|admin.)
CREATE POLICY exos_tickets_sel ON public.exos_tickets FOR SELECT TO authenticated
  USING (owner_id = auth.uid()
         OR buyer_id = auth.uid()
         OR exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));

-- events: let a ticket holder read the event their ticket is for, at ANY
-- status (phase-1 only exposed 'published' to non-staff; cancelled events must
-- stay visible to holders — see exos_holds_ticket above). Additive to the
-- phase-1 exos_events_sel_public / _sel_staff policies (RLS is permissive-OR).
CREATE POLICY exos_events_sel_ticketholder ON public.exos_events FOR SELECT TO authenticated
  USING (exos_holds_ticket(id));

-- transfers: sender, the receiver (email match), or org finance/management.
-- (firestore.rules transfers.get/list: senderId | receiverEmail == token email.)
CREATE POLICY exos_transfers_sel ON public.exos_transfers FOR SELECT TO authenticated
  USING (sender_id = auth.uid()
         OR lower(receiver_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         OR exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

-- check-in audit: org staff read; no client writes (RPC side effect only).
CREATE POLICY exos_checkins_sel ON public.exos_event_checkins FOR SELECT TO authenticated
  USING (exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));

-- scan rejects: org staff read; door staff (scanner+) write their own rows.
CREATE POLICY exos_scan_rejects_sel ON public.exos_scan_rejects FOR SELECT TO authenticated
  USING (exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
CREATE POLICY exos_scan_rejects_ins ON public.exos_scan_rejects FOR INSERT TO authenticated
  WITH CHECK (rejected_by = auth.uid()
              AND (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','scanner'])));

-- ---------------------------------------------------------------------------
-- Grants. As in phase-1 §8: REVOKE the Supabase platform-default privileges
-- (anon must touch NOTHING here — tickets/transfers are never public), then
-- re-GRANT only what each role needs. RLS still gates row visibility.
-- ---------------------------------------------------------------------------
REVOKE ALL ON
  public.exos_tickets, public.exos_transfers,
  public.exos_event_checkins, public.exos_scan_rejects
FROM anon, authenticated;

GRANT SELECT ON
  public.exos_tickets, public.exos_transfers,
  public.exos_event_checkins, public.exos_scan_rejects
TO authenticated;
GRANT INSERT ON public.exos_scan_rejects TO authenticated;

-- ===========================================================================
-- 7. Write-path RPCs (SECURITY DEFINER — the Postgres analogue of the
--    firestore.rules allow-create/allow-update branches). Each re-derives
--    auth.uid()/email and gates internally. Granted to `authenticated`.
-- ===========================================================================

-- 7a. Mint (comp / test / future webhook). Org-staff or admin only. Atomic
--     tier-capacity claim closes the oversell gap. capacity = 0 = unlimited.
CREATE OR REPLACE FUNCTION public.exos_mint_tickets(
  p_event_id   uuid,
  p_tier_id    uuid    DEFAULT NULL,
  p_quantity   int     DEFAULT 1,
  p_order_ref  text    DEFAULT NULL,
  p_price_paid numeric DEFAULT NULL,
  p_promoter_id text   DEFAULT NULL
) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_org       uuid;
  v_tier_name text;
  v_ids       uuid[] := '{}';
  v_id        uuid;
  i           int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_mint_tickets: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_quantity < 1 OR p_quantity > 10 THEN
    RAISE EXCEPTION 'exos_mint_tickets: quantity must be 1-10';
  END IF;

  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_mint_tickets: event not found';
  END IF;

  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_mint_tickets: not authorized for this event' USING ERRCODE = '42501';
  END IF;

  IF p_tier_id IS NOT NULL THEN
    UPDATE public.exos_ticket_tiers
       SET sold = sold + p_quantity
     WHERE id = p_tier_id
       AND event_id = p_event_id
       AND (capacity = 0 OR sold + p_quantity <= capacity)
    RETURNING name INTO v_tier_name;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos_mint_tickets: tier sold out or not found for this event';
    END IF;
  END IF;

  UPDATE public.exos_events
     SET tickets_sold = tickets_sold + p_quantity
   WHERE id = p_event_id;

  FOR i IN 1..p_quantity LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source, promoter_id
    ) VALUES (
      p_event_id, v_org, p_tier_id, v_tier_name, v_uid, v_uid,
      lower(coalesce(auth.jwt() ->> 'email', '')),
      'active', gen_random_uuid()::text, coalesce(p_price_paid, 0),
      p_order_ref, 'vibepass', p_promoter_id
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  RETURN v_ids;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_mint_tickets(uuid, uuid, int, text, numeric, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_mint_tickets(uuid, uuid, int, text, numeric, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_mint_tickets(uuid, uuid, int, text, numeric, text) TO authenticated;

-- 7b. Check in a ticket. Atomic flip (status must still be 'active') = the
--     double-scan guard. Writes the append-only audit row. Returns a result
--     object so the scanner UI can message the operator. Door staff only.
CREATE OR REPLACE FUNCTION public.exos_check_in_ticket(
  p_ticket_id    uuid,
  p_source       text DEFAULT 'manual',
  p_verification text DEFAULT 'manual'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_org     uuid;
  v_event   uuid;
  v_prev    text;
  v_pending uuid;
  v_updated int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT org_id, event_id, status, pending_transfer_id
    INTO v_org, v_event, v_prev, v_pending
    FROM public.exos_tickets WHERE id = p_ticket_id;
  IF v_org IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;

  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','scanner'])) THEN
    RAISE EXCEPTION 'exos_check_in_ticket: not authorized' USING ERRCODE = '42501';
  END IF;

  IF v_pending IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in-transfer');
  END IF;
  IF v_prev = 'voided' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'voided');
  END IF;
  IF v_prev = 'used' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'used');
  END IF;

  UPDATE public.exos_tickets
     SET status = 'used', check_in_at = now()
   WHERE id = p_ticket_id AND status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    -- Lost the race to a concurrent scan.
    RETURN jsonb_build_object('ok', false, 'reason', 'used');
  END IF;

  INSERT INTO public.exos_event_checkins
    (event_id, ticket_id, org_id, scanned_by, source, verification)
  VALUES (
    v_event, p_ticket_id, v_org, v_uid,
    CASE WHEN p_source IN ('camera','manual') THEN p_source ELSE 'manual' END,
    CASE WHEN p_verification IN ('verified','legacy','manual') THEN p_verification ELSE 'manual' END
  );

  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in');
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_check_in_ticket(uuid, text, text) TO authenticated;

-- 7c. Create a transfer + lock the ticket, atomically. Owner only; refuses
--     when the ticket isn't active, already has a pending lock, the receiver
--     is the sender, or the event is still a draft (receiver can't read it).
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

  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
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
   WHERE id = p_ticket_id;

  RETURN v_transfer_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_create_transfer(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_create_transfer(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_transfer(uuid, text) TO authenticated;

-- 7d. Cancel a pending transfer + clear the ticket lock. Sender only.
CREATE OR REPLACE FUNCTION public.exos_cancel_transfer(p_transfer_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  tr    public.exos_transfers%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_cancel_transfer: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO tr FROM public.exos_transfers WHERE id = p_transfer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_cancel_transfer: transfer not found';
  END IF;
  IF tr.sender_id <> v_uid THEN
    RAISE EXCEPTION 'exos_cancel_transfer: not the sender' USING ERRCODE = '42501';
  END IF;
  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_cancel_transfer: transfer is %', tr.status;
  END IF;

  UPDATE public.exos_transfers SET status = 'cancelled' WHERE id = p_transfer_id;
  UPDATE public.exos_tickets
     SET pending_transfer_id = NULL, last_reissue_at = now()
   WHERE id = tr.ticket_id AND pending_transfer_id = p_transfer_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_cancel_transfer(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_cancel_transfer(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_cancel_transfer(uuid) TO authenticated;

-- 7e. Claim a transfer: take ownership + ROTATE the barcode secret (so the
--     sender's old screenshot is dead) + clear the lock. Receiver-email match
--     + verified email required. Refuses if the ticket was used/voided since.
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

  UPDATE public.exos_tickets
     SET owner_id            = v_uid,
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

-- 7f. Void (refund) a ticket. Sticky once flipped. Owner/manager/finance staff
--     or admin. Mirrors firestore.rules tickets.update branch (4).
CREATE OR REPLACE FUNCTION public.exos_void_ticket(p_ticket_id uuid, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_org    uuid;
  v_status text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_void_ticket: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status INTO v_org, v_status FROM public.exos_tickets WHERE id = p_ticket_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_void_ticket: ticket not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager','finance'])) THEN
    RAISE EXCEPTION 'exos_void_ticket: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'exos_void_ticket: ticket is % (only an active ticket can be voided)', v_status;
  END IF;

  UPDATE public.exos_tickets
     SET status = 'voided', voided_at = now(), voided_by = v_uid,
         voided_reason = left(coalesce(p_reason, ''), 500)
   WHERE id = p_ticket_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_void_ticket(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_void_ticket(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_void_ticket(uuid, text) TO authenticated;
