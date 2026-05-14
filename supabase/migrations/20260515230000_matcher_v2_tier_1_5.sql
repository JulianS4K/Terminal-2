-- Migration 20260515230000 · level:admin · lane:Audit/Push · writes:match_to_aq_event_id() v2 (replaces v1 with new tier 1.5), match_unmatched_orders_sweep() v2 (propagates venue/performer short ids) · reads:aq_venue_map · pre:20260515220000
-- Matcher v2: insert Tier 1.5 (source venue_id + date) between current
-- Tier 1 and Tier 2. Also extend sweep to propagate venue_short_id and
-- performer_short_id onto order/sale tables when the AQ event resolves.
--
-- Tier 1.5 rationale: catches matches where the venue NAME has drifted
-- (rename, typo, abbreviation) but the source venue_id is stable.
-- For TickPick (raw.venue.id) and SG (sg_event_id -> sg_venue_id), we
-- JOIN aq_venue_map by source-specific venue id to resolve the
-- canonical venue_short_id, then filter aq_event_map by that
-- venue_short_id + date ±6h. Conf 0.93 — higher than fuzzy venue
-- (Tier 3) because we have a stable cross-source id; slightly lower
-- than direct event_id (Tier 1) because date+venue still allows
-- multi-event ambiguity within the window.
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14 (this session). Idempotent (CREATE OR REPLACE).
--
-- ## Regression risk
-- None. Function signature on match_to_aq_event_id adds an optional
-- `p_source_venue_id bigint` param; existing call sites continue to
-- work because it has a DEFAULT NULL.

-- ============================================================
-- 1. match_to_aq_event_id v2 — Tier 1.5 inserted
-- ============================================================

CREATE OR REPLACE FUNCTION public.match_to_aq_event_id(
  p_source           text,
  p_source_event_id  bigint,
  p_event_name       text,
  p_venue_name       text,
  p_event_date       timestamptz,
  p_lat              numeric DEFAULT NULL,
  p_lon              numeric DEFAULT NULL,
  p_source_venue_id  bigint  DEFAULT NULL    -- NEW in v2
)
RETURNS TABLE (
  aq_short_event_id  text,
  confidence         numeric(3,2),
  match_method       text
)
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_aq_id text;
  v_venue_short_id text;
BEGIN
  -- TIER 1: direct ID lookup
  IF p_source_event_id IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE (p_source IN ('vivid')              AND a.vivid_event_id = p_source_event_id)
       OR (p_source IN ('seatgeek','sg')      AND a.sg_event_id    = p_source_event_id)
       OR (p_source IN ('stubhub','sh')       AND a.sh_event_id    = p_source_event_id)
       OR (p_source IN ('ticketmaster','tm')  AND a.tm_event_id    = p_source_event_id)
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 1.00::numeric(3,2), 'tier1_direct_id'::text;
      RETURN;
    END IF;
  END IF;

  -- TIER 1.5: source venue_id -> aq_venue_map -> venue_short_id + date ±6h
  IF p_source_venue_id IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT m.venue_short_id INTO v_venue_short_id FROM public.aq_venue_map m
    WHERE (p_source IN ('tickpick')         AND m.tickpick_venue_id = p_source_venue_id)
       OR (p_source IN ('seatgeek','sg')    AND m.sg_venue_id       = p_source_venue_id)
       OR (p_source IN ('tevo','evo')       AND m.tevo_venue_id     = p_source_venue_id)
    LIMIT 1;
    IF v_venue_short_id IS NOT NULL THEN
      SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
      WHERE a.venue_short_id = v_venue_short_id
        AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                          AND p_event_date + interval '6 hours'
      ORDER BY abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date)))
      LIMIT 1;
      IF v_aq_id IS NOT NULL THEN
        RETURN QUERY SELECT v_aq_id, 0.93::numeric(3,2), 'tier1_5_venue_id_date'::text;
        RETURN;
      END IF;
    END IF;
  END IF;

  -- TIER 2: exact venue + date within ±6h
  IF p_venue_name IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE lower(trim(a.venue_name)) = lower(trim(p_venue_name))
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date)))
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.95::numeric(3,2), 'tier2_venue_exact_date'::text;
      RETURN;
    END IF;
  END IF;

  -- TIER 3: fuzzy venue (trigram >= 0.7) + date ±6h
  IF p_venue_name IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE similarity(lower(coalesce(a.venue_name,'')), lower(coalesce(p_venue_name,''))) >= 0.7
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY similarity(lower(a.venue_name), lower(p_venue_name)) DESC,
             abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date)))
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.80::numeric(3,2), 'tier3_venue_fuzzy_date'::text;
      RETURN;
    END IF;
  END IF;

  -- TIER 4: coord-based (~1km bbox) + date ±6h
  IF p_lat IS NOT NULL AND p_lon IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id
    FROM public.aq_event_map a
    JOIN public.venue_assets va ON lower(trim(va.venue_name)) = lower(trim(a.venue_name))
    WHERE va.latitude  BETWEEN p_lat - 0.01 AND p_lat + 0.01
      AND va.longitude BETWEEN p_lon - 0.02 AND p_lon + 0.02
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY (2 * 6371000 * asin(sqrt(
       power(sin(radians((va.latitude  - p_lat)/2)), 2)
       + cos(radians(p_lat)) * cos(radians(va.latitude))
         * power(sin(radians((va.longitude - p_lon)/2)), 2)
    )))
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.85::numeric(3,2), 'tier4_coord_date'::text;
      RETURN;
    END IF;
  END IF;

  RETURN;
END $$;

COMMENT ON FUNCTION public.match_to_aq_event_id IS
  'Multi-tier matcher v2: tier1 direct_id -> tier1.5 venue_id+date -> tier2 venue+date exact -> tier3 venue+date fuzzy -> tier4 coord+date. Returns empty set if nothing matches.';

-- ============================================================
-- 2. match_unmatched_orders_sweep v2 — propagates venue/performer short ids
-- ============================================================

CREATE OR REPLACE FUNCTION public.match_unmatched_orders_sweep(
  p_max_per_table  integer DEFAULT 500,
  p_create_synthetic boolean DEFAULT true
)
RETURNS TABLE (
  table_name       text,
  rows_examined    integer,
  rows_matched     integer,
  rows_synthetic   integer,
  rows_unmatched   integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  r RECORD;
  v_aq_id text; v_conf numeric(3,2); v_method text;
  v_venue_short_id text; v_performer_short_id text;
  v_matched int; v_synthetic int; v_examined int;
BEGIN
  -- VIVID  (no source venue_id available)
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT vivid_order_id, raw, event_name, event_date,
           (raw->'venue'->>'name')                AS v_venue,
           NULLIF(raw->>'productionId','')::bigint AS pid
    FROM public.vivid_orders
    WHERE aq_short_event_id IS NULL
      AND status <> 'ignored_tbd_postponed'
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('vivid', r.pid, r.event_name, r.v_venue, r.event_date) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('vivid', r.event_name, r.v_venue, r.event_date, r.pid);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short_id, v_performer_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.vivid_orders SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short_id),
        performer_short_id = coalesce(performer_short_id, v_performer_short_id)
      WHERE vivid_order_id = r.vivid_order_id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'vivid_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  -- TICKPICK  (raw.venue.id -> Tier 1.5)
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT tp_order_id, raw, event_name, event_date,
           (raw->'venue'->>'name')                          AS v_venue,
           NULLIF(raw->'venue'->>'id','')::bigint           AS source_vid,
           NULLIF(raw->'venue'->>'latitude','')::numeric    AS lat,
           NULLIF(raw->'venue'->>'longitude','')::numeric   AS lon,
           NULLIF(raw->>'event_date_utc','')::timestamptz   AS event_date_utc
    FROM public.tickpick_orders
    WHERE aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('tickpick', NULL,
           r.event_name, r.v_venue,
           coalesce(r.event_date_utc, r.event_date),
           r.lat, r.lon, r.source_vid) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('tickpick', r.event_name, r.v_venue,
                                               coalesce(r.event_date_utc, r.event_date));
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short_id, v_performer_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.tickpick_orders SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short_id),
        performer_short_id = coalesce(performer_short_id, v_performer_short_id)
      WHERE tp_order_id = r.tp_order_id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'tickpick_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  -- SEATGEEK_ORDERS (legacy seller-direct)
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT id, sg_order_id, sg_event_id, sg_event_name, sg_venue, sg_event_date
    FROM public.seatgeek_orders
    WHERE aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id,
                                     r.sg_event_name, r.sg_venue,
                                     r.sg_event_date::timestamptz) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.sg_event_name IS NOT NULL AND r.sg_event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.sg_event_name, r.sg_venue,
                                               r.sg_event_date::timestamptz, r.sg_event_id);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id INTO v_venue_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.seatgeek_orders SET
        aq_short_event_id = v_aq_id,
        venue_short_id    = coalesce(venue_short_id, v_venue_short_id)
      WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'seatgeek_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  -- SEATGEEK_SALES_SNAPSHOTS  (canonical JOIN for tiers 2-4, sg_venue_id for tier 1.5)
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT s.id, s.sg_event_id,
           c.sg_event_name   AS event_name,
           c.sg_venue_name   AS venue_name,
           c.sg_datetime_utc AS event_date,
           c.sg_venue_id     AS sg_venue_id
    FROM public.seatgeek_sales_snapshots s
    LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = s.sg_event_id
    WHERE s.aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id,
                                     r.event_name, r.venue_name, r.event_date,
                                     NULL, NULL, r.sg_venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.event_name, r.venue_name,
                                               r.event_date, r.sg_event_id);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id INTO v_venue_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.seatgeek_sales_snapshots SET
        aq_short_event_id = v_aq_id,
        venue_short_id    = coalesce(venue_short_id, v_venue_short_id)
      WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'seatgeek_sales_snapshots'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  -- EVO_ORDER_ITEMS (venue_id = TEvo venue id -> Tier 1.5)
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT i.id, i.event_id, i.event_name, i.venue_name, i.occurs_at, i.venue_id
    FROM public.evo_order_items i
    WHERE i.aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('evo', NULL,
                                     r.event_name, r.venue_name, r.occurs_at,
                                     NULL, NULL, r.venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.occurs_at IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('evo', r.event_name, r.venue_name, r.occurs_at);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short_id, v_performer_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.evo_order_items SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short_id),
        performer_short_id = coalesce(performer_short_id, v_performer_short_id)
      WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'evo_order_items'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;
END $$;

COMMENT ON FUNCTION public.match_unmatched_orders_sweep IS
  'v2: hourly sweep + propagates venue_short_id/performer_short_id. Calls match_to_aq_event_id v2 (which adds Tier 1.5 venue_id+date). Per-table caps via p_max_per_table.';
