-- ============================================================================
-- Migration 20260911131000 — Exos (Bridge / D4): self-serve RSVP release
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_tickets (W: +released_at; UPDATE status/voided_* on release),
--           exos_events (W: +allow_holder_release, +release_cutoff_hours;
--                        UPDATE tickets_sold),
--           exos_ticket_tiers (W: UPDATE sold — fires exos_tiers_waitlist_autooffer),
--           exos_release_ticket(uuid) (new, holder + staff RPC),
--           exos_event_analytics(uuid) (REPLACED — adds 'released', splits it out of 'voided')
-- Pre-reqs: 20260520130000 (exos_tickets / exos_void_ticket),
--           20260616220000 (waitlist auto-offer trigger on exos_ticket_tiers.sold),
--           20260911130000 (exos_event_analytics)
--
-- KANBAN D4-OPS-22 (Stage 3, organizer side). A free RSVP the holder can no
-- longer use should give its seat back. Today the only way out is a staff void,
-- and exos_void_ticket does NOT return capacity (a void is a refund: the money
-- action, not an inventory action) — so a sold-out free event with a waitlist
-- stays sold out even when holders drop.
--
-- Design:
--   * exos_release_ticket(ticket): ONE path, two callers.
--       holder  — must own the ticket; the event must allow holder release
--                 (allow_holder_release, default ON) and be more than
--                 release_cutoff_hours before start (default 0 = until start).
--       staff   — owner / manager / admin may release any FREE active ticket
--                 at any time (no-show cleanup, guest-list churn).
--     Both: ticket must be 'active', FREE (price_paid = 0 — a comp on a paid
--     tier is still free to the holder), not locked in a pending transfer.
--   * Effect: status → 'voided' (the scanner + wallet already refuse voided),
--     released_at stamped (so analytics / audit can tell a release from a
--     refund-void), tier.sold and event.tickets_sold decremented. The tier
--     decrement is what fires the existing waitlist auto-offer trigger, so the
--     next joiner gets a claim voucher without any new code.
--   * The attendee-facing button is the customer session's surface (bot_chat
--     flag filed); this migration exposes the RPC + the organizer controls.
--
-- ROLLBACK: DROP FUNCTION IF EXISTS public.exos_release_ticket(uuid);
--   ALTER TABLE exos_tickets DROP COLUMN released_at; ALTER TABLE exos_events
--   DROP COLUMN allow_holder_release, DROP COLUMN release_cutoff_hours;
--   re-create exos_event_analytics from 20260911130000.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_tickets
  ADD COLUMN IF NOT EXISTS released_at timestamptz;
COMMENT ON COLUMN public.exos_tickets.released_at IS
  'Set when the seat was given back via exos_release_ticket (status is voided; distinguishes a release from a refund-void).';

ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS allow_holder_release boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS release_cutoff_hours integer NOT NULL DEFAULT 0
    CHECK (release_cutoff_hours BETWEEN 0 AND 720);
COMMENT ON COLUMN public.exos_events.allow_holder_release IS
  'Organizer switch: may a holder release their own FREE ticket (exos_release_ticket)? Staff releases ignore this.';
COMMENT ON COLUMN public.exos_events.release_cutoff_hours IS
  'Holder self-release closes this many hours before starts_at (0 = up to the start time).';

-- ---------------------------------------------------------------------------
-- 2. Release RPC.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_release_ticket(p_ticket_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  t        public.exos_tickets%ROWTYPE;
  v_ev     public.exos_events%ROWTYPE;
  v_staff  boolean;
  v_reason text;
  v_freed  boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_release_ticket: not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_release_ticket: ticket not found';
  END IF;
  SELECT * INTO v_ev FROM public.exos_events WHERE id = t.event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_release_ticket: event not found';
  END IF;

  v_staff := exos_is_admin() OR exos_has_org_role(t.org_id, ARRAY['owner','manager']);
  IF NOT v_staff AND t.owner_id <> v_uid THEN
    RAISE EXCEPTION 'exos_release_ticket: not authorized' USING ERRCODE = '42501';
  END IF;

  IF t.status <> 'active' THEN
    RAISE EXCEPTION 'exos_release_ticket: ticket is % (only an active ticket can be released)', t.status;
  END IF;
  IF t.pending_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'exos_release_ticket: ticket is in a pending transfer — cancel it first';
  END IF;
  IF coalesce(t.price_paid, 0) <> 0 THEN
    RAISE EXCEPTION 'exos_release_ticket: only free tickets can be released — a paid ticket needs a refund';
  END IF;

  IF v_staff THEN
    v_reason := 'released-by-staff';
  ELSE
    -- Holder path: organizer policy + timing.
    IF NOT coalesce(v_ev.allow_holder_release, true) THEN
      RAISE EXCEPTION 'exos_release_ticket: the organizer has turned off self-serve release for this event';
    END IF;
    IF v_ev.status <> 'published' THEN
      RAISE EXCEPTION 'exos_release_ticket: event is not on sale';
    END IF;
    IF v_ev.starts_at IS NULL OR v_ev.starts_at <= now() THEN
      RAISE EXCEPTION 'exos_release_ticket: the event has already started';
    END IF;
    IF v_ev.starts_at - make_interval(hours => coalesce(v_ev.release_cutoff_hours, 0)) <= now() THEN
      RAISE EXCEPTION 'exos_release_ticket: releases closed % hours before the start time',
        coalesce(v_ev.release_cutoff_hours, 0);
    END IF;
    v_reason := 'released-by-holder';
  END IF;

  UPDATE public.exos_tickets
     SET status = 'voided', released_at = now(), voided_at = now(),
         voided_by = v_uid, voided_reason = v_reason
   WHERE id = p_ticket_id;

  -- Give the seat back. Tier first (this fires the waitlist auto-offer
  -- trigger when someone is waiting), then the house cap. v_freed reflects an
  -- ACTUAL decrement — a counter already at 0 means the books were off, so warn.
  IF t.tier_id IS NOT NULL THEN
    UPDATE public.exos_ticket_tiers
       SET sold = sold - 1
     WHERE id = t.tier_id AND sold > 0;
    v_freed := FOUND;
    IF NOT v_freed THEN
      RAISE WARNING 'exos_release_ticket: tier % sold counter was already 0 for ticket %', t.tier_id, p_ticket_id;
    END IF;
  END IF;
  UPDATE public.exos_events
     SET tickets_sold = tickets_sold - 1
   WHERE id = t.event_id AND tickets_sold > 0;
  IF NOT FOUND THEN
    RAISE WARNING 'exos_release_ticket: event % tickets_sold was already 0 for ticket %', t.event_id, p_ticket_id;
  END IF;
  -- A tier-less ticket never touches exos_ticket_tiers, so the auto-offer
  -- trigger cannot fire — offer the freed seat to the general waitlist directly.
  IF t.tier_id IS NULL THEN
    PERFORM public._exos_waitlist_offer_core(t.event_id, NULL, 1, 48);
    v_freed := true;
  END IF;

  RETURN jsonb_build_object(
    'ticket_id',   p_ticket_id,
    'released_at', now(),
    'by',          CASE WHEN v_staff THEN 'staff' ELSE 'holder' END,
    'freed_tier',  v_freed);
END $$;
REVOKE ALL ON FUNCTION public.exos_release_ticket(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_release_ticket(uuid) TO authenticated;

COMMENT ON FUNCTION public.exos_release_ticket(uuid) IS
  'D4 mig 20260911131000: give a FREE active ticket back. Holder (policy + cutoff gated) or owner/manager/admin. Voids the ticket, stamps released_at, decrements tier.sold + event.tickets_sold (fires waitlist auto-offer).';

-- ---------------------------------------------------------------------------
-- 3. Analytics: report releases separately from refund-voids.
--    Full body re-stated (same signature → CREATE OR REPLACE), only the
--    totals block and the returned keys change.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_analytics(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ev        public.exos_events%ROWTYPE;
  v_tz        text;
  v_started   boolean;
  v_sold      int;
  v_used      int;
  v_voided    int;
  v_released  int;
  v_revenue   numeric;
  v_first     timestamptz;
  v_last      timestamptz;
  v_by_day    jsonb;
  v_by_tier   jsonb;
  v_by_promo  jsonb;
  v_by_chan   jsonb;
  v_scans     jsonb;
  v_rejects   jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_analytics: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL THEN
    RAISE EXCEPTION 'exos_event_analytics: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_ev.org_id, ARRAY['owner','manager','finance'])) THEN
    RAISE EXCEPTION 'exos_event_analytics: not authorized' USING ERRCODE = '42501';
  END IF;

  v_tz := coalesce(nullif(v_ev.timezone, ''), 'UTC');
  BEGIN
    PERFORM now() AT TIME ZONE v_tz;
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE WARNING 'exos_event_analytics: event % has an invalid timezone (%) — using UTC', p_event_id, v_tz;
    v_tz := 'UTC';
  END;
  v_started := v_ev.starts_at IS NOT NULL AND v_ev.starts_at <= now();

  SELECT count(*) FILTER (WHERE status <> 'voided'),
         count(*) FILTER (WHERE status = 'used'),
         count(*) FILTER (WHERE status = 'voided' AND released_at IS NULL),
         count(*) FILTER (WHERE released_at IS NOT NULL),
         coalesce(sum(price_paid) FILTER (WHERE status <> 'voided'), 0),
         min(created_at) FILTER (WHERE status <> 'voided'),
         max(created_at) FILTER (WHERE status <> 'voided')
    INTO v_sold, v_used, v_voided, v_released, v_revenue, v_first, v_last
    FROM public.exos_tickets WHERE event_id = p_event_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'day', d.day, 'sold', d.sold, 'revenue', d.revenue, 'cumulative', d.cumulative)
           ORDER BY d.day), '[]'::jsonb)
    INTO v_by_day
    FROM (
      SELECT g.day, g.sold, g.revenue, sum(g.sold) OVER (ORDER BY g.day)::int AS cumulative
        FROM (
          SELECT to_char(created_at AT TIME ZONE v_tz, 'YYYY-MM-DD') AS day,
                 count(*)::int AS sold, coalesce(sum(price_paid), 0) AS revenue
            FROM public.exos_tickets
           WHERE event_id = p_event_id AND status <> 'voided'
           GROUP BY 1
        ) g
    ) d;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'tier_id', t.tier_id, 'tier', t.tier, 'sold', t.sold, 'used', t.used, 'revenue', t.revenue)
           ORDER BY t.sold DESC, t.tier), '[]'::jsonb)
    INTO v_by_tier
    FROM (
      SELECT tier_id, coalesce(tier_name, 'Standard') AS tier,
             count(*)::int AS sold, count(*) FILTER (WHERE status = 'used')::int AS used,
             coalesce(sum(price_paid), 0) AS revenue
        FROM public.exos_tickets
       WHERE event_id = p_event_id AND status <> 'voided'
       GROUP BY tier_id, coalesce(tier_name, 'Standard')
    ) t;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'promoter', p.promoter, 'sold', p.sold, 'used', p.used, 'revenue', p.revenue)
           ORDER BY p.sold DESC, p.promoter), '[]'::jsonb)
    INTO v_by_promo
    FROM (
      SELECT promoter_id AS promoter,
             count(*)::int AS sold, count(*) FILTER (WHERE status = 'used')::int AS used,
             coalesce(sum(price_paid), 0) AS revenue
        FROM public.exos_tickets
       WHERE event_id = p_event_id AND status <> 'voided'
         AND nullif(promoter_id, '') IS NOT NULL
       GROUP BY promoter_id
    ) p;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'channel', c.channel, 'sold', c.sold, 'used', c.used, 'revenue', c.revenue)
           ORDER BY c.sold DESC, c.channel), '[]'::jsonb)
    INTO v_by_chan
    FROM (
      SELECT coalesce(nullif(channel_source, ''), 'vibepass') AS channel,
             count(*)::int AS sold, count(*) FILTER (WHERE status = 'used')::int AS used,
             coalesce(sum(price_paid), 0) AS revenue
        FROM public.exos_tickets
       WHERE event_id = p_event_id AND status <> 'voided'
       GROUP BY 1
    ) c;

  SELECT jsonb_build_object(
           'total', count(*),
           'first_at', min(scanned_at),
           'last_at', max(scanned_at),
           'by_source', coalesce((SELECT jsonb_object_agg(s.k, s.n) FROM (
                          SELECT coalesce(source, 'unknown') AS k, count(*)::int AS n
                            FROM public.exos_event_checkins WHERE event_id = p_event_id GROUP BY 1) s), '{}'::jsonb),
           'by_verification', coalesce((SELECT jsonb_object_agg(s.k, s.n) FROM (
                          SELECT coalesce(verification, 'unknown') AS k, count(*)::int AS n
                            FROM public.exos_event_checkins WHERE event_id = p_event_id GROUP BY 1) s), '{}'::jsonb))
    INTO v_scans
    FROM public.exos_event_checkins WHERE event_id = p_event_id;

  SELECT jsonb_build_object(
           'total', count(*),
           'last_at', max(rejected_at),
           'by_reason', coalesce((SELECT jsonb_agg(jsonb_build_object('reason', r.reason, 'count', r.n) ORDER BY r.n DESC, r.reason)
                                    FROM (SELECT reason, count(*)::int AS n
                                            FROM public.exos_scan_rejects WHERE event_id = p_event_id GROUP BY reason) r),
                                 '[]'::jsonb))
    INTO v_rejects
    FROM public.exos_scan_rejects WHERE event_id = p_event_id;

  RETURN jsonb_build_object(
    'event_id',      p_event_id,
    'generated_at',  now(),
    'timezone',      v_tz,
    'event_started', v_started,
    'capacity',      v_ev.total_tickets,
    'sold',          v_sold,
    'used',          v_used,
    'unscanned',     v_sold - v_used,
    'voided',        v_voided,
    'released',      v_released,
    'revenue',       v_revenue,
    'checkin_rate',  CASE WHEN v_sold > 0 THEN round(v_used::numeric / v_sold, 4) END,
    'no_show_rate',  CASE WHEN v_started AND v_sold > 0 THEN round((v_sold - v_used)::numeric / v_sold, 4) END,
    'first_sale_at', v_first,
    'last_sale_at',  v_last,
    'sales_by_day',  v_by_day,
    'by_tier',       v_by_tier,
    'by_promoter',   v_by_promo,
    'by_channel',    v_by_chan,
    'scans',         v_scans,
    'rejects',       v_rejects
  );
END $$;
REVOKE ALL ON FUNCTION public.exos_event_analytics(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_event_analytics(uuid) TO authenticated;
