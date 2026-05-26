-- 20260526090000_exos_claim_free_tickets.sql
--
-- D4 free-first acquisition: a self-serve claim path so a signed-in attendee can
-- actually GET a ticket for a FREE tier. Until now the only mint path was
-- exos_mint_tickets (org-staff/admin comp only) — there was no buyer flow at all
-- (EventDetails showed "Coming soon"). Paid tiers still route through Stripe
-- checkout (dormant); this RPC hard-refuses any tier with a non-zero price.
--
-- Guards (all server-side, no admin bypass on this self-serve surface):
--   * authenticated caller; mints to themselves (buyer = owner = auth.uid())
--   * event must be 'published'
--   * tier must belong to the event, be price = 0, visibility public, and
--     within its sales window (sales_start/sales_end when set)
--   * per-person purchase limit enforced via exos_assert_purchase_limit
--   * atomic tier-capacity + event house-cap claim (same pattern as
--     exos_mint_tickets); sold-out → RAISE (rolls back the whole claim)
--   * captures promoter_id + channel_source from the landing URL (campaign
--     attribution → event Sales report); queues the ticket-issued mail
--     best-effort (a mail hiccup must not unwind a successful claim)
--
-- D4 authors; A1 applies. ⚠️ B1 review requested — this is a NEW self-serve
-- minting surface (authenticated → real exos_tickets rows).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.exos_claim_free_tickets(
  p_event_id    uuid,
  p_tier_id     uuid,
  p_quantity    int  DEFAULT 1,
  p_promoter_id text DEFAULT NULL,
  p_channel     text DEFAULT NULL
) RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_org        uuid;
  v_status     text;
  v_tier_name  text;
  v_price      numeric;
  v_vis        text;
  v_sstart     timestamptz;
  v_send       timestamptz;
  v_tier_event uuid;
  v_ids        uuid[] := '{}';
  v_id         uuid;
  v_updated    int;
  i            int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_quantity < 1 OR p_quantity > 10 THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: quantity must be 1-10';
  END IF;

  SELECT org_id, status INTO v_org, v_status
    FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: event not found';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: event not on sale' USING ERRCODE = '42501';
  END IF;

  SELECT name, price, visibility, sales_start, sales_end, event_id
    INTO v_tier_name, v_price, v_vis, v_sstart, v_send, v_tier_event
    FROM public.exos_ticket_tiers WHERE id = p_tier_id;
  IF v_tier_event IS NULL OR v_tier_event <> p_event_id THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: tier not found for this event';
  END IF;
  IF coalesce(v_price, 0) <> 0 THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: tier is not free — use checkout' USING ERRCODE = '42501';
  END IF;
  IF v_vis IS NOT NULL AND v_vis <> 'public' THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: tier not available' USING ERRCODE = '42501';
  END IF;
  IF v_sstart IS NOT NULL AND now() < v_sstart THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: sales have not started' USING ERRCODE = '42501';
  END IF;
  IF v_send IS NOT NULL AND now() > v_send THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: sales have ended' USING ERRCODE = '42501';
  END IF;

  -- Per-person limit (cumulative; no admin bypass on the self-serve path).
  PERFORM public.exos_assert_purchase_limit(p_event_id, v_uid, p_quantity);

  -- Atomic capacity claim — tier first, then the event house cap.
  UPDATE public.exos_ticket_tiers
     SET sold = sold + p_quantity
   WHERE id = p_tier_id AND event_id = p_event_id
     AND (capacity = 0 OR sold + p_quantity <= capacity);
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: tier sold out' USING ERRCODE = '23514';
  END IF;

  UPDATE public.exos_events
     SET tickets_sold = tickets_sold + p_quantity
   WHERE id = p_event_id
     AND (total_tickets = 0 OR tickets_sold + p_quantity <= total_tickets);
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'exos_claim_free_tickets: event sold out' USING ERRCODE = '23514';
  END IF;

  FOR i IN 1..p_quantity LOOP
    INSERT INTO public.exos_tickets (
      event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
      status, barcode_secret, price_paid, order_ref, channel_source, promoter_id
    ) VALUES (
      p_event_id, v_org, p_tier_id, v_tier_name, v_uid, v_uid,
      lower(coalesce(auth.jwt() ->> 'email', '')),
      'active', gen_random_uuid()::text, 0,
      'free_' || gen_random_uuid()::text,
      coalesce(nullif(p_channel, ''), 'vibepass'), nullif(p_promoter_id, '')
    ) RETURNING id INTO v_id;
    v_ids := array_append(v_ids, v_id);
    -- Confirmation mail (best-effort — never unwind the claim on a mail error).
    BEGIN
      PERFORM public.exos_queue_ticket_issued(v_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  RETURN v_ids;
END $$;

REVOKE ALL ON FUNCTION public.exos_claim_free_tickets(uuid, uuid, int, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_claim_free_tickets(uuid, uuid, int, text, text) TO authenticated;

-- ROLLBACK: DROP FUNCTION IF EXISTS public.exos_claim_free_tickets(uuid, uuid, int, text, text);
