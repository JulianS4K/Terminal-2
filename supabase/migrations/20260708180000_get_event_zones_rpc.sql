-- ============================================================================
-- Migration 20260708180000 — get_event_zones(): live per-zone metrics RPC
--
-- Lane:     A1 data plane (SECDEF read RPC; consumed by the D0 event page
--           "Zone Metrics" panel).
-- Touches:  get_event_zones (W/function)
-- Reads:    get_event_zones_rollup (live curated/fallback zones + qty + retail
--           bounds), zone_metrics (fuller per-zone distribution)
-- Pre-reqs: 20260509050000-era get_event_zones_rollup; zone_metrics.
--
-- WHY. The event page's "Zone Metrics" panel (re-added 2026-07-07) read the
-- consolidated page payload's `data.zones` key. But production loads the page
-- via get_broker_event_page_v3, which returns only `zone_deltas` — it has NO
-- `zones` key — so the panel rendered empty for EVERY event on the live site
-- (it only worked on the localhost /zones REST fallback). Compounding it, the
-- one place zones DID come from (the cron-fed zone_metrics table) goes stale for
-- rescheduled events (e.g. Yankees 3091424 froze 2026-06-22), so even that path
-- showed pre-remap zones, never the current curated set.
--
-- This RPC gives the front-end a direct, SECDEF, always-fresh zones source it
-- can fetch in parallel with the (heavy, timeout-prone) page RPC — mirroring the
-- broker_event_zones REST endpoint's "live curated overlay" logic:
--   * zone LIST + qty + retail min/max come LIVE from get_event_zones_rollup
--     (curated preferred; fallback only when no curated zones exist), so newly-
--     mapped venues + the latest listings surface immediately;
--   * the fuller distribution (median / p75 / wholesale / owned / sections) is
--     enriched from the latest zone_metrics row per zone when present (null when
--     the cron hasn't landed one — same graceful degradation as the REST route);
--   * get-in defaults to the live min-retail when zone_metrics lacks one;
--   * parking/garage/hospitality zones are hidden unless opted in.
--
-- SECDEF because get_event_zones_rollup + performer_zones + zone_metrics are
-- RLS-locked; the browser client (authenticated @s4kent.com JWT) can't read them
-- directly. Email-gated like the other D0 read RPCs.
--
-- ROLLBACK: DROP FUNCTION get_event_zones(bigint, boolean).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_event_zones(
  p_event_id       bigint,
  p_include_parking boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email  text;
  v_src    text;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH live AS (
    SELECT r.zone, r.source, r.tickets, r.min_retail, r.max_retail
    FROM public.get_event_zones_rollup(p_event_id, false) r
    WHERE r.zone IS NOT NULL
  ),
  chosen AS (
    -- curated wins; fall back only when the event has no curated zones at all.
    SELECT CASE
             WHEN EXISTS (SELECT 1 FROM live WHERE source = 'curated')  THEN 'curated'
             WHEN EXISTS (SELECT 1 FROM live WHERE source = 'fallback') THEN 'fallback'
             ELSE NULL
           END AS src
  ),
  picked AS (
    SELECT l.*
    FROM live l CROSS JOIN chosen c
    WHERE l.source = c.src
      AND (p_include_parking
           OR l.zone !~* '\y(parking|garage|valet|lot|hospitality)\y')
  ),
  zm AS (
    -- latest zone_metrics row per zone for the fuller distribution.
    SELECT DISTINCT ON (zone) zone, sections_count, retail_median, retail_p75,
           wholesale_median, owned_tickets_count, owned_share, getin_price
    FROM public.zone_metrics
    WHERE event_id = p_event_id AND zone IS NOT NULL
    ORDER BY zone, captured_at DESC
  )
  SELECT jsonb_build_object(
    'zones', coalesce(jsonb_agg(jsonb_build_object(
        'zone',                p.zone,
        'tickets_count',       p.tickets,
        'sections_count',      zm.sections_count,
        'getin_price',         coalesce(zm.getin_price, p.min_retail),
        'retail_min',          p.min_retail,
        'retail_median',       zm.retail_median,
        'retail_p75',          zm.retail_p75,
        'retail_max',          p.max_retail,
        'wholesale_median',    zm.wholesale_median,
        'owned_tickets_count', zm.owned_tickets_count,
        'owned_share',         zm.owned_share
      ) ORDER BY p.tickets DESC NULLS LAST), '[]'::jsonb),
    'count',  count(p.zone),
    'source', (SELECT src FROM chosen),
    'live',   true
  ) INTO v_result
  FROM picked p LEFT JOIN zm ON zm.zone = p.zone;

  RETURN coalesce(v_result, jsonb_build_object('zones', '[]'::jsonb, 'count', 0, 'source', NULL, 'live', true));
END;
$func$;

REVOKE ALL ON FUNCTION public.get_event_zones(bigint, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_zones(bigint, boolean) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_zones(bigint, boolean) IS
  'D0 event page — live per-zone metrics for the Zone Metrics panel. Zone list + qty + retail bounds come live from get_event_zones_rollup (curated>fallback); median/p75/wholesale/owned enriched from latest zone_metrics per zone. Decouples zones from the heavy get_broker_event_page_v3 (which has no zones key). Email-gated SECDEF; FE fetches in parallel and setZonesTevo(result).';
