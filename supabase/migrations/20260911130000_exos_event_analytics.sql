-- ============================================================================
-- Migration 20260911130000 — Exos (Bridge / D4): organizer event analytics RPC
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_event_analytics(uuid) (new, staff RPC — read-only),
--           exos_tickets (R), exos_event_checkins (R), exos_scan_rejects (R),
--           exos_events (R), exos_ticket_tiers (R)
-- Pre-reqs: 20260520130000 (exos_tickets / exos_event_checkins / exos_scan_rejects),
--           20260605132000 (event-scoped check-in — checkins carry event_id)
--
-- KANBAN D4-OPS-24 (Stage 3, organizer side). The event report computed tier /
-- promoter / channel rollups client-side from the full ticket list and had no
-- scan-in or no-show view at all (ScanReport counts scans but never joins them
-- back to the attribution axes). This RPC returns ONE jsonb document with every
-- rollup the report + CSV export need, computed server-side under the same
-- role gate the report already applies (owner / manager / finance / admin):
--
--   sold          non-voided tickets (active + used)
--   used          tickets scanned in (status = 'used')
--   no_show_rate  (sold - used) / sold — only once the event has STARTED;
--                 NULL before that (a pre-event "no-show" is meaningless)
--   sales_by_day  daily + cumulative, bucketed in the EVENT's timezone
--   by_tier / by_promoter / by_channel  sold · used · revenue per axis
--   scans         checkin audit rollup (by source / verification, first/last)
--   rejects       exos_scan_rejects rollup by reason (+ last_at)
--
-- Read-only: no writes, no side effects. Buyer identity is NOT in the document
-- (the attendee CSV is built client-side from the RLS-gated ticket read that the
-- report already performs). Day bucketing falls back to UTC on a bad timezone
-- rather than failing (same posture as the reminders migration).
--
-- ROLLBACK: DROP FUNCTION IF EXISTS public.exos_event_analytics(uuid);
-- ============================================================================

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

  -- Validate the timezone once; a bad name degrades to UTC, never errors.
  v_tz := coalesce(nullif(v_ev.timezone, ''), 'UTC');
  BEGIN
    PERFORM now() AT TIME ZONE v_tz;
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE WARNING 'exos_event_analytics: event % has an invalid timezone (%) — using UTC', p_event_id, v_tz;
    v_tz := 'UTC';
  END;
  v_started := v_ev.starts_at IS NOT NULL AND v_ev.starts_at <= now();

  -- Totals over the ticket set.
  SELECT count(*) FILTER (WHERE status <> 'voided'),
         count(*) FILTER (WHERE status = 'used'),
         count(*) FILTER (WHERE status = 'voided'),
         coalesce(sum(price_paid) FILTER (WHERE status <> 'voided'), 0),
         min(created_at) FILTER (WHERE status <> 'voided'),
         max(created_at) FILTER (WHERE status <> 'voided')
    INTO v_sold, v_used, v_voided, v_revenue, v_first, v_last
    FROM public.exos_tickets WHERE event_id = p_event_id;

  -- Sales by day (event tz), with a running cumulative.
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

  -- Attribution axes, each with scan-in.
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

  -- Door: successful scans (append-only audit log).
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

  -- Door: refused scans.
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

COMMENT ON FUNCTION public.exos_event_analytics(uuid) IS
  'D4 mig 20260911130000: one-call organizer analytics document (sold/used/no-show, sales-by-day in event tz, tier/promoter/channel with scan-in, checkin + reject rollups). Owner/manager/finance/admin. Read-only.';
