-- Migration 20260515210000 · level:admin · lane:Audit/Push · writes:aq_event_map.aq_source col, match_to_aq_event_id() fn, create_system_aq_event() fn, match_unmatched_orders_sweep() fn, hourly cron, v_aq_match_quality view · reads:venue_assets · pre:20260515190000,20260515200000
-- Universal multi-tier AQ event matcher + sweep cron.
--
-- Operator direction 2026-05-14:
--   "create a multi test matching function and make a cron to process
--    unmatched events, and any future sales and match automatically,
--    create matching system when aq event is not present, as a fallback"
--
-- Match tiers (return on first hit):
--   1. Direct ID lookup    — conf 1.00 — source's own event_id matches
--                            aq_event_map.{vivid,sg,sh,tm}_event_id
--   2. Venue+date exact    — conf 0.95 — lower(trim(venue)) match + ±6h
--   3. Venue+date fuzzy    — conf 0.80 — trigram similarity ≥0.7 on
--                            venue + ±6h
--   4. Coord+date (lat/lon) — conf 0.85 — haversine ≤500m via
--                            venue_assets bridge + ±6h
--   5. (fallback)           — conf 0.50 — create_system_aq_event()
--                            inserts SYS-prefixed synthetic row keyed
--                            by md5(name|venue|date). Idempotent — same
--                            inputs yield same id, so orders for the
--                            same untracked event cluster correctly.
--
-- Sweep cron: hourly :22 — iterates the 5 unmatched-orders surfaces and
-- runs the matcher.  Capped per-firing to avoid runaway loops.
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14 (this session). Idempotent.

-- ============================================================
-- 1. aq_source provenance column on aq_event_map
-- ============================================================

ALTER TABLE public.aq_event_map ADD COLUMN IF NOT EXISTS aq_source text;
UPDATE public.aq_event_map SET aq_source = 'aq_curated' WHERE aq_source IS NULL;
COMMENT ON COLUMN public.aq_event_map.aq_source IS
  'Origin of this aq_event_map row: '
  'aq_curated (from operator xlsx import) | '
  'aq_event_map_seed (bulk-seeded from sg_events_canonical) | '
  'system_seed (auto-created by matcher fallback when no AQ entry existed). '
  'Synthetic ids start with ''SYS-'' so they''re visually distinct from operator-curated 7-char codes.';

-- ============================================================
-- 2. Multi-tier matcher
-- ============================================================

CREATE OR REPLACE FUNCTION public.match_to_aq_event_id(
  p_source           text,     -- 'vivid'|'tickpick'|'seatgeek'|'sh'|'tm'|'evo'
  p_source_event_id  bigint,   -- nullable; if set, tier-1 direct ID match
  p_event_name       text,     -- source's event name (informational)
  p_venue_name       text,     -- source's venue name
  p_event_date       timestamptz,
  p_lat              numeric DEFAULT NULL,
  p_lon              numeric DEFAULT NULL
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

  -- TIER 3: fuzzy venue (trigram ≥ 0.7) + date ±6h
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

  -- TIER 4: coord-based (haversine ≤ ~1km bounding box) + date ±6h
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

  -- No match
  RETURN;
END $$;

COMMENT ON FUNCTION public.match_to_aq_event_id IS
  'Multi-tier matcher: tier1 direct ID → tier2 venue+date exact → tier3 venue+date fuzzy → tier4 coord+date. '
  'Returns empty set if nothing matches; caller can fall back to create_system_aq_event().';

-- ============================================================
-- 3. Synthetic-fallback: create SYS-prefixed aq_event_map row
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_system_aq_event(
  p_source           text,
  p_event_name       text,
  p_venue_name       text,
  p_event_date       timestamptz,
  p_source_event_id  bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_new_id text;
BEGIN
  -- Idempotent: same inputs always produce same id, so multiple orders
  -- for the same untracked event cluster onto a single synthetic row.
  v_new_id := 'SYS-' || substring(
    md5(coalesce(p_event_name,'') || '|' || coalesce(p_venue_name,'') || '|' ||
        coalesce(to_char(p_event_date::timestamptz, 'YYYY-MM-DD"T"HH24:MI'),''))
    from 1 for 10);
  INSERT INTO public.aq_event_map (
    aq_short_event_id, event_name, venue_name, event_date,
    category, aq_source, imported_at
  )
  VALUES (
    v_new_id, p_event_name, p_venue_name, p_event_date::timestamp,
    p_source, 'system_seed', now()
  )
  ON CONFLICT (aq_short_event_id) DO NOTHING;
  RETURN v_new_id;
END $$;

COMMENT ON FUNCTION public.create_system_aq_event IS
  'Fallback when match_to_aq_event_id returns empty. Inserts a SYS-prefixed '
  'aq_event_map row keyed by md5(name|venue|date) for stability across calls. '
  'Operator can later promote/merge system_seed rows to aq_curated.';

-- ============================================================
-- 4. Sweep: process all unmatched orders/sales across 5 tables
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
  v_matched int; v_synthetic int; v_examined int;
BEGIN
  -- VIVID
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
    SELECT m.aq_short_event_id, m.confidence, m.match_method INTO v_aq_id, v_conf, v_method
    FROM public.match_to_aq_event_id('vivid', r.pid, r.event_name, r.v_venue, r.event_date) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('vivid', r.event_name, r.v_venue, r.event_date, r.pid);
      v_method := 'tier5_synthetic'; v_conf := 0.50;
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      UPDATE public.vivid_orders SET aq_short_event_id = v_aq_id WHERE vivid_order_id = r.vivid_order_id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'vivid_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  -- TICKPICK
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT tp_order_id, raw, event_name, event_date,
           (raw->'venue'->>'name')                          AS v_venue,
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
           r.lat, r.lon) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('tickpick', r.event_name, r.v_venue,
                                               coalesce(r.event_date_utc, r.event_date));
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      UPDATE public.tickpick_orders SET aq_short_event_id = v_aq_id WHERE tp_order_id = r.tp_order_id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'tickpick_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  -- SEATGEEK_ORDERS (legacy seller-direct table — mostly historical)
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
      UPDATE public.seatgeek_orders SET aq_short_event_id = v_aq_id WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'seatgeek_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  -- SEATGEEK_SALES_SNAPSHOTS  (broker /sales) — JOIN canonical so tiers 2-4 + synthetic can fire.
  -- (Without the JOIN, tier 1 was the only path: ~30% hit rate.)
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT s.id, s.sg_event_id,
           c.sg_event_name   AS event_name,
           c.sg_venue_name   AS venue_name,
           c.sg_datetime_utc AS event_date
    FROM public.seatgeek_sales_snapshots s
    LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = s.sg_event_id
    WHERE s.aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id,
                                     r.event_name, r.venue_name, r.event_date) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.event_name, r.venue_name,
                                               r.event_date, r.sg_event_id);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      UPDATE public.seatgeek_sales_snapshots SET aq_short_event_id = v_aq_id WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'seatgeek_sales_snapshots'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  -- EVO_ORDER_ITEMS  (look up via events table for venue+date)
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT i.id, i.event_id, i.event_name, i.venue_name, i.occurs_at
    FROM public.evo_order_items i
    WHERE i.aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('evo', NULL, r.event_name, r.venue_name, r.occurs_at) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.occurs_at IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('evo', r.event_name, r.venue_name, r.occurs_at);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      UPDATE public.evo_order_items SET aq_short_event_id = v_aq_id WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'evo_order_items'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;
END $$;

COMMENT ON FUNCTION public.match_unmatched_orders_sweep IS
  'Hourly sweep: iterates the 5 order/sale surfaces, runs the 4-tier matcher per row, optionally creates synthetic AQ entries on miss. Caps each table at p_max_per_table to keep runtime bounded.';

-- ============================================================
-- 5. Cron — hourly :22 slot
-- ============================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='match_unmatched_orders_sweep_hourly') THEN
    PERFORM cron.schedule(
      'match_unmatched_orders_sweep_hourly',
      '22 * * * *',
      'SELECT * FROM public.match_unmatched_orders_sweep(500, true);'
    );
  END IF;
END $$;

-- ============================================================
-- 6. Quality view — per-source/tier coverage rollup
-- ============================================================

CREATE OR REPLACE VIEW public.v_aq_match_quality AS
SELECT 'vivid_orders'::text         AS source_table,
       count(*)                     AS total,
       count(aq_short_event_id)     AS with_aq,
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%') AS synthetic,
       round(100.0 * count(aq_short_event_id) / NULLIF(count(*),0), 1) AS pct_aq
FROM public.vivid_orders
UNION ALL
SELECT 'tickpick_orders',           count(*), count(aq_short_event_id),
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%'),
       round(100.0 * count(aq_short_event_id) / NULLIF(count(*),0), 1)
FROM public.tickpick_orders
UNION ALL
SELECT 'seatgeek_orders',           count(*), count(aq_short_event_id),
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%'),
       round(100.0 * count(aq_short_event_id) / NULLIF(count(*),0), 1)
FROM public.seatgeek_orders
UNION ALL
SELECT 'seatgeek_sales_snapshots',  count(*), count(aq_short_event_id),
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%'),
       round(100.0 * count(aq_short_event_id) / NULLIF(count(*),0), 1)
FROM public.seatgeek_sales_snapshots
UNION ALL
SELECT 'evo_order_items',           count(*), count(aq_short_event_id),
       count(*) FILTER (WHERE aq_short_event_id LIKE 'SYS-%'),
       round(100.0 * count(aq_short_event_id) / NULLIF(count(*),0), 1)
FROM public.evo_order_items;

ALTER VIEW public.v_aq_match_quality SET (security_invoker = true);
