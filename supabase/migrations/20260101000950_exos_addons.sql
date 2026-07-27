-- ============================================================================
-- Migration 20260616190000 — Exos (Bridge / D4): product add-ons (merch)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_event_addons (W, new), exos_order_addons (W, new),
--           exos_public_addons (W, new view), exos_checkout_sessions (+addons col),
--           exos_fulfill_checkout / exos_refund_checkout (REPLACE — add-on aware),
--           exos_claim_free_addons (W, new RPC); reads exos_events/orgs
-- Pre-reqs: 20260520120000 (events/tiers/has_org_role), 20260523170000
--           (checkout sessions + fulfill/refund), 20260523150000 (total cap)
--
-- Feature parity with Hi.Events' product add-ons (merch / extras sold alongside
-- a ticket). Full integration (operator-approved 2026-06-16):
--   * exos_event_addons — organizer-managed catalog per event (price + capacity).
--   * Buyer selects add-ons; the paid checkout edge fn adds them as Stripe line
--     items and stores them on the session (new addons jsonb col). Fulfillment
--     records the purchase (exos_order_addons) + bumps sold EXACTLY ONCE (same
--     idempotent gate as ticket mint). Refund reverses both.
--   * Free path: exos_claim_free_addons attaches $0 extras to a free claim.
--     Paid add-ons hard-refuse on the free path (must go through checkout) —
--     mirrors exos_claim_free_tickets' price=0 guard.
-- Security mirrors phase-1: deny-by-default RLS; staff CRUD their own event's
-- catalog; anon browses ONLY the column-narrowed exos_public_addons view; the
-- order ledger is written by SECDEF/service_role only.
-- D4 authors; A1 applies to prod (AFTER the operator finalizes the Stripe model).
-- ============================================================================

-- ===========================================================================
-- 1. Add-on catalog (organizer-managed; mirrors exos_ticket_tiers shape).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_event_addons (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id      uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  name          text NOT NULL,
  description   text,
  price         numeric NOT NULL DEFAULT 0 CHECK (price >= 0),
  capacity      integer NOT NULL DEFAULT 0 CHECK (capacity >= 0),   -- 0 = unlimited
  sold          integer NOT NULL DEFAULT 0 CHECK (sold >= 0),
  max_per_order integer CHECK (max_per_order IS NULL OR max_per_order >= 1),
  visibility    text NOT NULL DEFAULT 'public' CHECK (visibility IN ('public','hidden')),
  image_url     text,
  sort_order    integer NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_addons_event_idx ON public.exos_event_addons (event_id);

-- ===========================================================================
-- 2. Add-on purchase ledger (what was actually bought; snapshots name + price).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_order_addons (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- Keep the row if the catalog entry is later deleted (purchase history stands).
  addon_id        uuid REFERENCES public.exos_event_addons (id) ON DELETE SET NULL,
  addon_name      text,
  buyer_id        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  owner_id        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  quantity        integer NOT NULL CHECK (quantity BETWEEN 1 AND 50),
  unit_price_paid numeric NOT NULL DEFAULT 0 CHECK (unit_price_paid >= 0),
  order_ref       text,                 -- checkout session_id OR free-claim ref
  channel_source  text,                 -- 'stripe' | 'free' | 'comp'
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','refunded','voided')),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_order_addons_event_idx ON public.exos_order_addons (event_id);
CREATE INDEX IF NOT EXISTS exos_order_addons_order_idx ON public.exos_order_addons (order_ref);
CREATE INDEX IF NOT EXISTS exos_order_addons_buyer_idx ON public.exos_order_addons (buyer_id);

-- updated_at touch on the catalog (ledger rows are immutable except status).
DROP TRIGGER IF EXISTS exos_event_addons_touch ON public.exos_event_addons;
CREATE TRIGGER exos_event_addons_touch BEFORE UPDATE ON public.exos_event_addons
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ===========================================================================
-- 3. RLS — deny-by-default (mirrors tiers + checkout_sessions).
-- ===========================================================================
ALTER TABLE public.exos_event_addons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_order_addons ENABLE ROW LEVEL SECURITY;

-- Catalog: own-org staff read/write (same scoping as exos_ticket_tiers). Buyers
-- browse other orgs' add-ons via exos_public_addons (§ below).
CREATE POLICY exos_addons_sel_staff ON public.exos_event_addons FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager','finance','scanner','content'])));
CREATE POLICY exos_addons_wr ON public.exos_event_addons FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])));

-- Order ledger: buyer reads own rows; org staff read the event's. No client
-- writes (SECDEF fulfillment / free-claim RPC + service_role write it).
CREATE POLICY exos_order_addons_sel ON public.exos_order_addons FOR SELECT TO authenticated
  USING (buyer_id = auth.uid() OR owner_id = auth.uid()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

-- Strip platform-default grants; re-grant only what's needed (RLS gates rows).
REVOKE ALL ON public.exos_event_addons FROM anon, authenticated;
REVOKE ALL ON public.exos_order_addons FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON public.exos_event_addons TO authenticated;
GRANT  SELECT ON public.exos_order_addons TO authenticated;

-- Anon/buyer browse surface: public add-ons of PUBLISHED events only, column-
-- narrowed + visibility-gated. Owner-run (the view IS the boundary), SELECT-only.
CREATE OR REPLACE VIEW public.exos_public_addons AS
  SELECT a.id, a.event_id, a.name, a.description, a.price, a.capacity, a.sold,
         a.max_per_order, a.image_url, a.sort_order
  FROM public.exos_event_addons a
  JOIN public.exos_events e ON e.id = a.event_id
  WHERE a.visibility = 'public' AND e.status = 'published';
REVOKE ALL ON public.exos_public_addons FROM anon, authenticated;
GRANT  SELECT ON public.exos_public_addons TO anon, authenticated;

-- ===========================================================================
-- 4. Carry the selected add-ons on the checkout session (edge fn writes;
--    fulfillment reads). Shape: [{addon_id, quantity, unit_price_cents, name}].
-- ===========================================================================
ALTER TABLE public.exos_checkout_sessions ADD COLUMN IF NOT EXISTS addons jsonb;

-- ===========================================================================
-- 5. exos_fulfill_checkout — REPLACE: same idempotent gate, now also records
--    add-on purchases + bumps sold (exactly once, inside the mint tx).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_fulfill_checkout(p_session_id text)
RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s          public.exos_checkout_sessions%ROWTYPE;
  v_tier_name text;
  v_updated  int;
  v_ids      uuid[] := '{}';
  v_id       uuid;
  v_evname   text;
  v_safe     text;
  i          int;
  r          record;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: unknown session %', p_session_id;
  END IF;

  IF s.status = 'fulfilled' THEN
    RETURN coalesce(s.ticket_ids, '{}');
  END IF;
  IF s.status <> 'pending' THEN
    RETURN '{}'::uuid[];
  END IF;

  -- Tier capacity claim (atomic). NULL tier = no per-tier cap.
  IF s.tier_id IS NOT NULL THEN
    UPDATE public.exos_ticket_tiers
       SET sold = sold + s.quantity
     WHERE id = s.tier_id AND event_id = s.event_id
       AND (capacity = 0 OR sold + s.quantity <= capacity)
    RETURNING name INTO v_tier_name;
    IF NOT FOUND THEN
      UPDATE public.exos_checkout_sessions
         SET status='failed', failure_reason='tier sold out at fulfillment'
       WHERE session_id = p_session_id;
      RETURN '{}'::uuid[];
    END IF;
  END IF;

  -- Event house cap (atomic).
  UPDATE public.exos_events
     SET tickets_sold = tickets_sold + s.quantity
   WHERE id = s.event_id
     AND (total_tickets = 0 OR tickets_sold + s.quantity <= total_tickets);
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    UPDATE public.exos_checkout_sessions
       SET status='failed', failure_reason='event sold out at fulfillment'
     WHERE session_id = p_session_id;
    RETURN '{}'::uuid[];
  END IF;

  -- Mint to the buyer.
  FOR i IN 1..s.quantity LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source
    ) VALUES (
      s.event_id, s.org_id, s.tier_id, v_tier_name, s.buyer_uid, s.buyer_uid,
      lower(coalesce(s.buyer_email, '')),
      'active', gen_random_uuid()::text,
      round((s.amount_cents::numeric / 100) / s.quantity, 2),
      p_session_id, 'stripe'
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  -- Fulfill add-ons. The buyer already paid (amount_cents includes them), so we
  -- record + bump sold WITHOUT a hard cap re-check: capacity was gated at
  -- session creation, and failing a PAID fulfillment over a swag cap would
  -- strand the charge. A rare oversell of merch is refundable.
  IF s.addons IS NOT NULL AND jsonb_typeof(s.addons) = 'array' THEN
    FOR r IN
      SELECT * FROM jsonb_to_recordset(s.addons)
        AS x(addon_id uuid, quantity int, unit_price_cents int, name text)
    LOOP
      IF r.addon_id IS NULL OR coalesce(r.quantity, 0) < 1 THEN CONTINUE; END IF;
      UPDATE public.exos_event_addons
         SET sold = sold + r.quantity
       WHERE id = r.addon_id AND event_id = s.event_id;
      INSERT INTO public.exos_order_addons (
        event_id, org_id, addon_id, addon_name, buyer_id, owner_id,
        quantity, unit_price_paid, order_ref, channel_source, status
      ) VALUES (
        s.event_id, s.org_id, r.addon_id, r.name, s.buyer_uid, s.buyer_uid,
        r.quantity, round(coalesce(r.unit_price_cents, 0)::numeric / 100, 2),
        p_session_id, 'stripe', 'active'
      );
    END LOOP;
  END IF;

  UPDATE public.exos_checkout_sessions
     SET status='fulfilled', ticket_ids=v_ids, fulfilled_at=now()
   WHERE session_id = p_session_id;

  -- Buyer confirmation mail (best-effort; never unwinds a paid fulfillment).
  IF coalesce(s.buyer_email, '') <> '' THEN
    SELECT name INTO v_evname FROM public.exos_events WHERE id = s.event_id;
    v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');
    BEGIN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES (
        'ticket-issued', lower(s.buyer_email),
        left('Your ticket' || CASE WHEN s.quantity > 1 THEN 's' ELSE '' END ||
             ' for ' || v_safe || ' ' || CASE WHEN s.quantity > 1 THEN 'are' ELSE 'is' END || ' ready', 200),
        '<p>Payment received — your ' || s.quantity::text || ' ticket' ||
          CASE WHEN s.quantity > 1 THEN 's' ELSE '' END ||
          ' for <strong>' || v_safe ||
          '</strong> ' || CASE WHEN s.quantity > 1 THEN 'are' ELSE 'is' END ||
          ' in your wallet. Open the app to show your QR at the door.</p>',
        s.buyer_uid, 'pending'
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;

  RETURN v_ids;
END $$;
REVOKE ALL ON FUNCTION public.exos_fulfill_checkout(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_fulfill_checkout(text) TO service_role;

-- ===========================================================================
-- 6. exos_refund_checkout — REPLACE: also reverse the session's add-ons.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_refund_checkout(
  p_session_id text,
  p_reason     text DEFAULT 'refunded'
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s     public.exos_checkout_sessions%ROWTYPE;
  v_n   int := 0;
  r     record;
BEGIN
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_refund_checkout: unknown session %', p_session_id;
  END IF;
  IF s.status = 'refunded' THEN
    RETURN 0;
  END IF;

  -- Void the session's active tickets; free ticket inventory per voided ticket.
  FOR r IN
    UPDATE public.exos_tickets
       SET status = 'voided', voided_at = now(),
           voided_reason = left(coalesce(p_reason, 'refunded'), 500)
     WHERE order_ref = p_session_id AND status = 'active'
    RETURNING tier_id
  LOOP
    v_n := v_n + 1;
    IF r.tier_id IS NOT NULL THEN
      UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = r.tier_id;
    END IF;
  END LOOP;

  IF v_n > 0 THEN
    UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_n) WHERE id = s.event_id;
  END IF;

  -- Reverse add-ons purchased on this session: mark refunded + free their stock.
  FOR r IN
    UPDATE public.exos_order_addons
       SET status = 'refunded'
     WHERE order_ref = p_session_id AND status = 'active'
    RETURNING addon_id, quantity
  LOOP
    IF r.addon_id IS NOT NULL THEN
      UPDATE public.exos_event_addons SET sold = greatest(0, sold - r.quantity) WHERE id = r.addon_id;
    END IF;
  END LOOP;

  UPDATE public.exos_checkout_sessions
     SET status = 'refunded', failure_reason = left(coalesce(p_reason, 'refunded'), 500)
   WHERE session_id = p_session_id;

  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_refund_checkout(text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_refund_checkout(text, text) TO service_role;

-- ===========================================================================
-- 7. exos_claim_free_addons — attach $0 extras to a free claim. Paid add-ons
--    hard-refuse (must go through checkout), mirroring exos_claim_free_tickets.
--    Authenticated buyer = owner. Returns count attached.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_claim_free_addons(
  p_event_id  uuid,
  p_order_ref text,
  p_addons    jsonb
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_org    uuid;
  v_status text;
  v_count  int := 0;
  r        record;
  a        public.exos_event_addons%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_claim_free_addons: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status INTO v_org, v_status FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_claim_free_addons: event not found';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_claim_free_addons: event not on sale' USING ERRCODE = '42501';
  END IF;
  IF p_addons IS NULL OR jsonb_typeof(p_addons) <> 'array' THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_addons) AS x(addon_id uuid, quantity int)
  LOOP
    IF r.addon_id IS NULL OR coalesce(r.quantity, 0) < 1 THEN CONTINUE; END IF;
    SELECT * INTO a FROM public.exos_event_addons
      WHERE id = r.addon_id AND event_id = p_event_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos_claim_free_addons: add-on not found for this event';
    END IF;
    IF a.visibility <> 'public' THEN
      RAISE EXCEPTION 'exos_claim_free_addons: add-on not available';
    END IF;
    IF coalesce(a.price, 0) <> 0 THEN
      RAISE EXCEPTION 'exos_claim_free_addons: add-on is not free — use checkout' USING ERRCODE = '42501';
    END IF;
    -- Atomic capacity claim (free extras DO honor the cap — unlike the paid
    -- fulfillment path where the buyer already paid).
    UPDATE public.exos_event_addons
       SET sold = sold + r.quantity
     WHERE id = a.id AND (capacity = 0 OR sold + r.quantity <= capacity);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos_claim_free_addons: add-on "%" is sold out', a.name;
    END IF;

    INSERT INTO public.exos_order_addons (
      event_id, org_id, addon_id, addon_name, buyer_id, owner_id,
      quantity, unit_price_paid, order_ref, channel_source, status
    ) VALUES (
      p_event_id, v_org, a.id, a.name, v_uid, v_uid,
      r.quantity, 0, nullif(p_order_ref, ''), 'free', 'active'
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.exos_claim_free_addons(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_claim_free_addons(uuid, text, jsonb) TO authenticated;

COMMENT ON TABLE public.exos_event_addons IS
  'D4 mig 20260616190000: organizer-managed product add-ons (merch). Buyer selects
   → paid checkout line items (exos-checkout) → exos_fulfill_checkout records
   exos_order_addons + bumps sold; refund reverses. Free $0 extras via
   exos_claim_free_addons. RLS deny-by-default; anon browses exos_public_addons.';
