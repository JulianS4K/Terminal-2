-- ============================================================================
-- Migration 20260708170000 — get_event_face(): unified primary "face" (AXS + TM)
--
-- Lane:     A1 data plane (SECDEF read RPC; consumed by D0 event page + Leagues
--           hub slates + movers/watchlist — the "face for primary" surfaces).
-- Touches:  get_event_face (W/function)
-- Reads:    v_axs_listings (AXS primary), ticketsdata_listings_snapshots (TM
--           primary), latest_event_metrics (secondary get-in)
-- Pre-reqs: 20260620153000 (v_event_primary_vs_secondary / v_axs_listings),
--           20260526090000 (ticketsdata foundation)
--
-- WHY. Where a PRIMARY seller (Ticketmaster or AXS) lists an event, that price
-- is the face value — the true primary-market anchor the secondary market
-- (TEvo / SeatGeek resale) is measured against. AXS face was already computed
-- (v_event_primary_vs_secondary, AXS-only, alerts-facing) but never surfaced in
-- the terminal, and Ticketmaster face (TicketsData platform='TM') wasn't folded
-- in at all. This RPC unifies both into one batch lookup the front-end merges
-- by event_id (same pattern as get_nascar_tickets):
--   face_getin = min primary get-in across AXS + TM
--   face_source = which primary(s) set it ('AXS' | 'TM' | 'AXS+TM')
--   signal      = below_face (secondary cheaper than face — a flip) /
--                 secondary_premium (resale ≥ face) / no_secondary
--
-- Batch + event-scoped: both source reads filter on event_id = ANY(p_event_ids)
-- so the huge ticketsdata_listings_snapshots table is hit only through
-- idx_td_ls_event_platform_cap (event_id, platform, captured_at DESC) — never a
-- full scan. Parking listings + non-positive prices are excluded from face.
--
-- ROLLBACK: DROP FUNCTION get_event_face(bigint[]).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_event_face(p_event_ids bigint[])
RETURNS TABLE (
  event_id        bigint,
  face_getin      numeric,
  face_median     numeric,
  face_qty        bigint,
  face_source     text,
  axs_getin       numeric,
  tm_getin        numeric,
  secondary_getin numeric,
  signal          text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH ids AS (
    SELECT DISTINCT x AS event_id FROM unnest(coalesce(p_event_ids, '{}'::bigint[])) AS x
  ),
  -- AXS primary = latest AXS snapshot per event, min positive primary retail.
  latest_axs AS (
    SELECT ae.tevo_event_id, max(ae.last_snapshot_id) AS snap
    FROM public.axs_events ae
    JOIN ids ON ids.event_id = ae.tevo_event_id
    WHERE ae.tevo_event_id IS NOT NULL AND ae.last_snapshot_id IS NOT NULL
    GROUP BY ae.tevo_event_id
  ),
  axs AS (
    SELECT l.event_id,
           min(l.retail_price) FILTER (WHERE l.retail_price > 0)                                   AS getin,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY l.retail_price) FILTER (WHERE l.retail_price > 0) AS med,
           sum(l.quantity) FILTER (WHERE l.retail_price > 0)                                        AS qty
    FROM public.v_axs_listings l
    JOIN latest_axs la ON la.tevo_event_id = l.event_id AND la.snap = l.snapshot_id
    WHERE l.src = 'primary'
    GROUP BY l.event_id
  ),
  -- Ticketmaster primary = latest TD 'TM' snapshot per event, min positive
  -- non-parking list price. Event+platform scoped → uses idx_td_ls_event_platform_cap.
  tm_latest AS (
    SELECT s.event_id, max(s.captured_at) AS cap
    FROM public.ticketsdata_listings_snapshots s
    JOIN ids ON ids.event_id = s.event_id
    WHERE s.platform = 'TM'
    GROUP BY s.event_id
  ),
  tm AS (
    SELECT s.event_id,
           min(s.list_price) FILTER (WHERE s.list_price > 0 AND NOT coalesce(s.is_parking, false))          AS getin,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY s.list_price) FILTER (WHERE s.list_price > 0 AND NOT coalesce(s.is_parking, false)) AS med,
           sum(s.quantity) FILTER (WHERE s.list_price > 0 AND NOT coalesce(s.is_parking, false))            AS qty
    FROM public.ticketsdata_listings_snapshots s
    JOIN tm_latest t ON t.event_id = s.event_id AND t.cap = s.captured_at
    WHERE s.platform = 'TM'
    GROUP BY s.event_id
  ),
  merged AS (
    SELECT i.event_id,
           a.getin AS axs_getin, a.med AS axs_med, a.qty AS axs_qty,
           t.getin AS tm_getin,  t.med AS tm_med,  t.qty AS tm_qty
    FROM ids i
    LEFT JOIN axs a ON a.event_id = i.event_id
    LEFT JOIN tm  t ON t.event_id = i.event_id
    WHERE a.getin IS NOT NULL OR t.getin IS NOT NULL   -- only events that HAVE a face
  )
  SELECT m.event_id,
         LEAST(coalesce(m.axs_getin, m.tm_getin), coalesce(m.tm_getin, m.axs_getin))          AS face_getin,
         -- face_median follows whichever source set the get-in (ties → AXS).
         CASE WHEN m.tm_getin IS NOT NULL AND (m.axs_getin IS NULL OR m.tm_getin < m.axs_getin)
              THEN m.tm_med ELSE coalesce(m.axs_med, m.tm_med) END                            AS face_median,
         coalesce(m.axs_qty, 0) + coalesce(m.tm_qty, 0)                                       AS face_qty,
         CASE WHEN m.axs_getin IS NOT NULL AND m.tm_getin IS NOT NULL THEN 'AXS+TM'
              WHEN m.tm_getin IS NOT NULL THEN 'TM' ELSE 'AXS' END                            AS face_source,
         m.axs_getin, m.tm_getin,
         lem.getin_price AS secondary_getin,
         CASE WHEN lem.getin_price IS NULL THEN 'no_secondary'
              WHEN lem.getin_price < LEAST(coalesce(m.axs_getin, m.tm_getin), coalesce(m.tm_getin, m.axs_getin)) THEN 'below_face'
              ELSE 'secondary_premium' END                                                    AS signal
  FROM merged m
  LEFT JOIN public.latest_event_metrics lem ON lem.event_id = m.event_id;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_event_face(bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_face(bigint[]) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_face(bigint[]) IS
  'D0 face value — batch primary-market get-in per event, unified across AXS (v_axs_listings src=primary) and Ticketmaster (ticketsdata platform=TM). Returns face_getin/median/qty + face_source + a below_face/secondary_premium signal vs latest_event_metrics get-in. Event-scoped (idx_td_ls_event_platform_cap); email-gated read-only. FE merges by event_id.';
