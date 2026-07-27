-- ============================================================================
-- Migration 20260523150000 — Exos (Bridge / D4): enforce event-level cap in mint
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_mint_tickets() RPC (CREATE OR REPLACE — same signature)
-- Pre-reqs: 20260520130000 (exos_mint_tickets, exos_tickets, exos_ticket_tiers)
--
-- D4-OPS-5 — event-level oversell. The mint RPC enforced per-tier `capacity`
-- but never the event's `total_tickets`, so `tickets_sold` could exceed the
-- advertised house, and a NULL-tier mint was unbounded. The scanner UI shows
-- `total_tickets` as "Total Authorized" (OrganizerCheckIn) — make it a real cap.
--
-- Semantics (mirrors tier capacity): total_tickets = 0 means UNCAPPED (the
-- column DEFAULT — not every event configures a house cap). When > 0, a mint
-- that would push tickets_sold past it is refused.
--
-- Atomic: the cap is enforced in the same UPDATE that bumps tickets_sold (guard
-- in the WHERE + ROW_COUNT check). Because the whole RPC runs in one
-- transaction, RAISE rolls back the tier-counter increment done just above too —
-- no partial state. CREATE OR REPLACE keeps the existing signature, so no new
-- overload is created (see PROJECT_BIBLE §7 "drop old overloads" landmine).
--
-- D4 authors; A1 applies to prod.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_mint_tickets(
  p_event_id    uuid,
  p_tier_id     uuid    DEFAULT NULL,
  p_quantity    int     DEFAULT 1,
  p_order_ref   text    DEFAULT NULL,
  p_price_paid  numeric DEFAULT NULL,
  p_promoter_id text    DEFAULT NULL
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
  v_updated   int;
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

  -- Per-tier capacity (atomic claim). capacity = 0 = unlimited.
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

  -- Event-level house cap (atomic). total_tickets = 0 = uncapped. On failure
  -- the RAISE rolls back the tier increment above (single transaction).
  UPDATE public.exos_events
     SET tickets_sold = tickets_sold + p_quantity
   WHERE id = p_event_id
     AND (total_tickets = 0 OR tickets_sold + p_quantity <= total_tickets);
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'exos_mint_tickets: event sold out — total_tickets cap reached'
      USING ERRCODE = '23514';
  END IF;

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

REVOKE EXECUTE ON FUNCTION public.exos_mint_tickets(uuid, uuid, int, text, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_mint_tickets(uuid, uuid, int, text, numeric, text) TO authenticated;
