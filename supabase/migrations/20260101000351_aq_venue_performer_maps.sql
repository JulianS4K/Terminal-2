-- Migration 20260515220000 · level:admin · lane:Audit/Push · writes:aq_venue_map (new), aq_performer_map (new), aq_event_map.venue_short_id/performer_short_id (new cols + FK), order-table venue_short_id cols · reads:tickpick_orders.raw, sg_events_canonical, entity_performer_map, venue_assets · pre:20260515210000
-- Cross-source venue + performer ID maps.
--
-- Operator direction 2026-05-14 (after universal matcher landed):
--   "see if each source sends a unique venue and performer ids so we can
--    map them 1-1 to strengthen the matching further"
--
-- Per-source venue ID coverage (probed):
--   Vivid:    ❌ free-text only
--   TickPick: ✓ raw.venue.id (100% in our 910 orders)
--   SG:       ✓ sg_events_canonical.sg_venue_id
--   TEvo:     ✓ venue_assets.tevo_venue_id (the TEvo venue table is venue_assets here)
--   AQ xlsx:  ❌ only venue_name + city + state
--
-- Per-source performer ID:
--   AQ xlsx: ✓ "Performer Id" UUID + "AQ Performer Id" short code (NOT in current DB —
--              gated on operator re-supplying the xlsx with cols 7/35/44)
--   TEvo:    ✓ entity_performer_map.tevo_performer_id
--   Others:  none
--
-- Strategy: build new aq_venue_map/aq_performer_map tables (broader than the
-- existing entity_* maps which are TEvo-centric and only cover 383/377 rows).
-- Cover all distinct (name,city,state) tuples from aq_event_map + tickpick.raw
-- + sg_events_canonical + venue_assets. Short codes generated deterministically
-- so two sources hitting the same name+city+state get the same short id.
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14 (this session). Idempotent — CREATE TABLE IF NOT EXISTS
-- + INSERT ON CONFLICT DO NOTHING throughout.
--
-- ## Regression risk
-- None to release_health_check categories. New tables, no view rewrites, no
-- cron changes. FK adds use NOT VALID + VALIDATE to avoid blocking locks.

-- ============================================================
-- 1. aq_venue_map
-- ============================================================

CREATE TABLE IF NOT EXISTS public.aq_venue_map (
  venue_short_id     text PRIMARY KEY,
  venue_name         text NOT NULL,
  city               text,
  state              text,
  country            text DEFAULT 'US',
  tevo_venue_id      bigint UNIQUE,
  sg_venue_id        bigint UNIQUE,
  tickpick_venue_id  bigint UNIQUE,
  latitude           numeric,
  longitude          numeric,
  aq_source          text DEFAULT 'curated',     -- 'curated' | 'system_seed'
  imported_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.aq_venue_map IS
  'Cross-source canonical venue table. PK venue_short_id is deterministic short code (1+2+4 chars from city/state/name-hash). Carries per-source venue IDs from TEvo, SG, TickPick (Vivid has no venue_id).';

CREATE INDEX IF NOT EXISTS aq_venue_map_name_city_state_idx
  ON public.aq_venue_map (lower(venue_name), lower(coalesce(city,'')), lower(coalesce(state,'')));

-- ============================================================
-- 2. aq_performer_map
-- ============================================================

CREATE TABLE IF NOT EXISTS public.aq_performer_map (
  performer_short_id  text PRIMARY KEY,
  performer_name      text NOT NULL,
  performer_uuid      uuid,                        -- AQ-internal Performer Id (NULL until xlsx re-extract)
  tevo_performer_id   bigint UNIQUE,
  category            text,                        -- inherits from entity_performer_map.top_category_name when joinable
  aq_source           text DEFAULT 'curated',
  imported_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.aq_performer_map IS
  'Cross-source canonical performer table. Vivid/TickPick/SG /sales don''t expose performer IDs — TEvo + AQ xlsx are the only sources. performer_uuid stays NULL until operator supplies the xlsx with the "Performer Id" col 7.';

CREATE INDEX IF NOT EXISTS aq_performer_map_name_idx
  ON public.aq_performer_map (lower(performer_name));

-- ============================================================
-- 3. Helper: short-code generator
-- ============================================================

CREATE OR REPLACE FUNCTION public.aq_venue_short_id(
  p_name  text, p_city text, p_state text
) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, extensions, pg_temp
AS $$
  SELECT upper(left(coalesce(p_city, 'X'), 1))
      || upper(left(coalesce(p_state, 'XX'), 2))
      || upper(substring(
           md5(lower(coalesce(p_name,'') || '|' || coalesce(p_city,'') || '|' || coalesce(p_state,'')))
           from 1 for 4));
$$;

CREATE OR REPLACE FUNCTION public.aq_performer_short_id(p_name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = public, extensions, pg_temp
AS $$
  SELECT upper(left(coalesce(p_name,'X'), 2))
      || upper(substring(md5(lower(coalesce(p_name,''))) from 1 for 5));
$$;

COMMENT ON FUNCTION public.aq_venue_short_id IS
  'Deterministic 7-char venue short id: city-initial + state-2 + 4-char hash. Same name+city+state → same id, so two sources for the same venue cluster onto a single map row.';
COMMENT ON FUNCTION public.aq_performer_short_id IS
  'Deterministic 7-char performer short id: 2-char name prefix + 5-char hash. Will be superseded by AQ xlsx-provided AQ Performer Id when available.';

-- ============================================================
-- 4. Seed aq_venue_map from aq_event_map distinct (name, city, state)
-- ============================================================

-- Seed from ALL aq_event_map rows (including SYS-) so the FK from aq_event_map
-- to aq_venue_map is satisfied for every row that gets a computed venue_short_id.
INSERT INTO public.aq_venue_map (venue_short_id, venue_name, city, state, aq_source)
SELECT DISTINCT ON (public.aq_venue_short_id(venue_name, city, state))
  public.aq_venue_short_id(venue_name, city, state),
  venue_name, city, state,
  CASE WHEN aq_source = 'system_seed' THEN 'system_seed' ELSE 'curated' END
FROM public.aq_event_map
WHERE venue_name IS NOT NULL
ON CONFLICT (venue_short_id) DO NOTHING;

-- ============================================================
-- 5. Cross-link: tevo_venue_id from venue_assets (join on name+city+state)
-- ============================================================

UPDATE public.aq_venue_map m SET tevo_venue_id = va.tevo_venue_id,
                                  latitude  = coalesce(m.latitude,  va.latitude),
                                  longitude = coalesce(m.longitude, va.longitude)
FROM public.venue_assets va
WHERE m.tevo_venue_id IS NULL
  AND lower(trim(m.venue_name)) = lower(trim(va.venue_name))
  AND lower(coalesce(m.city,''))  = lower(coalesce(va.city,''))
  AND lower(coalesce(m.state,'')) = lower(coalesce(va.state,''))
  -- avoid duplicate tevo_venue_id assignment via UNIQUE constraint
  AND NOT EXISTS (
    SELECT 1 FROM public.aq_venue_map m2 WHERE m2.tevo_venue_id = va.tevo_venue_id
  );

-- ============================================================
-- 6. Cross-link: sg_venue_id from sg_events_canonical
-- ============================================================

UPDATE public.aq_venue_map m SET sg_venue_id = sub.sg_venue_id
FROM (
  SELECT DISTINCT ON (lower(trim(sg_venue_name)), lower(coalesce(sg_venue_city,'')), lower(coalesce(sg_venue_state,'')))
    sg_venue_id, sg_venue_name, sg_venue_city, sg_venue_state
  FROM public.sg_events_canonical
  WHERE sg_venue_id IS NOT NULL AND sg_venue_name IS NOT NULL
  ORDER BY lower(trim(sg_venue_name)), lower(coalesce(sg_venue_city,'')), lower(coalesce(sg_venue_state,'')), sg_venue_id
) sub
WHERE m.sg_venue_id IS NULL
  AND lower(trim(m.venue_name)) = lower(trim(sub.sg_venue_name))
  AND lower(coalesce(m.city,''))  = lower(coalesce(sub.sg_venue_city,''))
  AND lower(coalesce(m.state,'')) = lower(coalesce(sub.sg_venue_state,''))
  AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map m2 WHERE m2.sg_venue_id = sub.sg_venue_id);

-- Seed venues that SG knows but aq_event_map doesn't (city+state from SG)
INSERT INTO public.aq_venue_map (venue_short_id, venue_name, city, state, country, sg_venue_id, aq_source)
SELECT
  public.aq_venue_short_id(sg_venue_name, sg_venue_city, sg_venue_state),
  sg_venue_name, sg_venue_city, sg_venue_state, coalesce(sg_venue_country, 'US'),
  sg_venue_id, 'system_seed'
FROM (
  SELECT DISTINCT ON (sg_venue_id)
    sg_venue_id, sg_venue_name, sg_venue_city, sg_venue_state, sg_venue_country
  FROM public.sg_events_canonical
  WHERE sg_venue_id IS NOT NULL AND sg_venue_name IS NOT NULL
  ORDER BY sg_venue_id
) sg
WHERE NOT EXISTS (SELECT 1 FROM public.aq_venue_map m WHERE m.sg_venue_id = sg.sg_venue_id)
ON CONFLICT (venue_short_id) DO UPDATE SET
  sg_venue_id = EXCLUDED.sg_venue_id
  WHERE aq_venue_map.sg_venue_id IS NULL;

-- ============================================================
-- 7. Cross-link: tickpick_venue_id from tickpick_orders.raw->'venue'
-- ============================================================

WITH tp_venues AS (
  SELECT DISTINCT ON ((raw->'venue'->>'id')::bigint)
    (raw->'venue'->>'id')::bigint    AS tp_id,
    raw->'venue'->>'name'            AS tp_name,
    raw->'venue'->>'city'            AS tp_city,
    raw->'venue'->>'state'           AS tp_state,
    NULLIF(raw->'venue'->>'latitude','')::numeric  AS tp_lat,
    NULLIF(raw->'venue'->>'longitude','')::numeric AS tp_lon
  FROM public.tickpick_orders
  WHERE (raw->'venue'->>'id') IS NOT NULL
  ORDER BY (raw->'venue'->>'id')::bigint
)
UPDATE public.aq_venue_map m SET tickpick_venue_id = tp.tp_id,
                                  latitude  = coalesce(m.latitude,  tp.tp_lat),
                                  longitude = coalesce(m.longitude, tp.tp_lon)
FROM tp_venues tp
WHERE m.tickpick_venue_id IS NULL
  AND lower(trim(m.venue_name)) = lower(trim(tp.tp_name))
  AND lower(coalesce(m.city,''))  = lower(coalesce(tp.tp_city,''))
  AND lower(coalesce(m.state,'')) = lower(coalesce(tp.tp_state,''))
  AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map m2 WHERE m2.tickpick_venue_id = tp.tp_id);

-- Seed venues TickPick knows but we don't (still pickable by id)
INSERT INTO public.aq_venue_map (venue_short_id, venue_name, city, state, tickpick_venue_id, latitude, longitude, aq_source)
SELECT
  public.aq_venue_short_id(tp_name, tp_city, tp_state),
  tp_name, tp_city, tp_state, tp_id, tp_lat, tp_lon, 'system_seed'
FROM (
  SELECT DISTINCT ON ((raw->'venue'->>'id')::bigint)
    (raw->'venue'->>'id')::bigint    AS tp_id,
    raw->'venue'->>'name'            AS tp_name,
    raw->'venue'->>'city'            AS tp_city,
    raw->'venue'->>'state'           AS tp_state,
    NULLIF(raw->'venue'->>'latitude','')::numeric  AS tp_lat,
    NULLIF(raw->'venue'->>'longitude','')::numeric AS tp_lon
  FROM public.tickpick_orders
  WHERE (raw->'venue'->>'id') IS NOT NULL
  ORDER BY (raw->'venue'->>'id')::bigint
) tp
WHERE NOT EXISTS (SELECT 1 FROM public.aq_venue_map m WHERE m.tickpick_venue_id = tp.tp_id)
ON CONFLICT (venue_short_id) DO UPDATE SET
  tickpick_venue_id = EXCLUDED.tickpick_venue_id,
  latitude  = coalesce(aq_venue_map.latitude,  EXCLUDED.latitude),
  longitude = coalesce(aq_venue_map.longitude, EXCLUDED.longitude)
  WHERE aq_venue_map.tickpick_venue_id IS NULL;

-- ============================================================
-- 8. Seed aq_performer_map from aq_event_map.performer + entity_performer_map
-- ============================================================

INSERT INTO public.aq_performer_map (performer_short_id, performer_name, aq_source)
SELECT DISTINCT ON (public.aq_performer_short_id(performer))
  public.aq_performer_short_id(performer),
  performer,
  CASE WHEN aq_source = 'system_seed' THEN 'system_seed' ELSE 'curated' END
FROM public.aq_event_map
WHERE performer IS NOT NULL AND length(trim(performer)) > 0
ON CONFLICT (performer_short_id) DO NOTHING;

-- Cross-link tevo_performer_id from entity_performer_map by name
UPDATE public.aq_performer_map p SET tevo_performer_id = ep.tevo_performer_id,
                                      category          = ep.top_category_name
FROM public.entity_performer_map ep
WHERE p.tevo_performer_id IS NULL
  AND lower(trim(p.performer_name)) = lower(trim(ep.tevo_performer_name))
  AND NOT EXISTS (SELECT 1 FROM public.aq_performer_map p2 WHERE p2.tevo_performer_id = ep.tevo_performer_id);

-- ============================================================
-- 9. aq_event_map: add venue_short_id + performer_short_id FK cols + backfill
-- ============================================================

ALTER TABLE public.aq_event_map ADD COLUMN IF NOT EXISTS venue_short_id text;
ALTER TABLE public.aq_event_map ADD COLUMN IF NOT EXISTS performer_short_id text;

UPDATE public.aq_event_map a
SET venue_short_id = public.aq_venue_short_id(a.venue_name, a.city, a.state)
WHERE venue_short_id IS NULL AND venue_name IS NOT NULL;

UPDATE public.aq_event_map a
SET performer_short_id = public.aq_performer_short_id(a.performer)
WHERE performer_short_id IS NULL AND performer IS NOT NULL;

-- FKs (NOT VALID for instant apply, then VALIDATE)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'aq_event_map_venue_short_id_fkey'
  ) THEN
    ALTER TABLE public.aq_event_map
      ADD CONSTRAINT aq_event_map_venue_short_id_fkey
      FOREIGN KEY (venue_short_id) REFERENCES public.aq_venue_map(venue_short_id) NOT VALID;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'aq_event_map_performer_short_id_fkey'
  ) THEN
    ALTER TABLE public.aq_event_map
      ADD CONSTRAINT aq_event_map_performer_short_id_fkey
      FOREIGN KEY (performer_short_id) REFERENCES public.aq_performer_map(performer_short_id) NOT VALID;
  END IF;
END $$;

ALTER TABLE public.aq_event_map VALIDATE CONSTRAINT aq_event_map_venue_short_id_fkey;
ALTER TABLE public.aq_event_map VALIDATE CONSTRAINT aq_event_map_performer_short_id_fkey;

-- ============================================================
-- 10. Order/sale tables: add venue_short_id (performer_short_id for the
--     tables where the column will eventually be wired)
-- ============================================================

ALTER TABLE public.vivid_orders                 ADD COLUMN IF NOT EXISTS venue_short_id text;
ALTER TABLE public.tickpick_orders              ADD COLUMN IF NOT EXISTS venue_short_id text;
ALTER TABLE public.seatgeek_orders              ADD COLUMN IF NOT EXISTS venue_short_id text;
ALTER TABLE public.seatgeek_sales_snapshots     ADD COLUMN IF NOT EXISTS venue_short_id text;
ALTER TABLE public.seatgeek_listings_snapshots  ADD COLUMN IF NOT EXISTS venue_short_id text;
ALTER TABLE public.evo_order_items              ADD COLUMN IF NOT EXISTS venue_short_id text;

ALTER TABLE public.vivid_orders                 ADD COLUMN IF NOT EXISTS performer_short_id text;
ALTER TABLE public.tickpick_orders              ADD COLUMN IF NOT EXISTS performer_short_id text;
ALTER TABLE public.evo_order_items              ADD COLUMN IF NOT EXISTS performer_short_id text;

-- Backfill via aq_event_map join (where aq_short_event_id is resolved)
UPDATE public.vivid_orders v SET venue_short_id = a.venue_short_id, performer_short_id = a.performer_short_id
FROM public.aq_event_map a
WHERE v.aq_short_event_id = a.aq_short_event_id
  AND (v.venue_short_id IS NULL OR v.performer_short_id IS NULL);

UPDATE public.tickpick_orders t SET venue_short_id = a.venue_short_id, performer_short_id = a.performer_short_id
FROM public.aq_event_map a
WHERE t.aq_short_event_id = a.aq_short_event_id
  AND (t.venue_short_id IS NULL OR t.performer_short_id IS NULL);

UPDATE public.seatgeek_orders s SET venue_short_id = a.venue_short_id
FROM public.aq_event_map a
WHERE s.aq_short_event_id = a.aq_short_event_id AND s.venue_short_id IS NULL;

UPDATE public.seatgeek_sales_snapshots s SET venue_short_id = a.venue_short_id
FROM public.aq_event_map a
WHERE s.aq_short_event_id = a.aq_short_event_id AND s.venue_short_id IS NULL;

UPDATE public.seatgeek_listings_snapshots s SET venue_short_id = a.venue_short_id
FROM public.aq_event_map a
WHERE s.aq_short_event_id = a.aq_short_event_id AND s.venue_short_id IS NULL;

UPDATE public.evo_order_items e SET venue_short_id = a.venue_short_id, performer_short_id = a.performer_short_id
FROM public.aq_event_map a
WHERE e.aq_short_event_id = a.aq_short_event_id
  AND (e.venue_short_id IS NULL OR e.performer_short_id IS NULL);

COMMENT ON COLUMN public.vivid_orders.venue_short_id IS
  'Inherited from aq_event_map.venue_short_id when aq_short_event_id is resolved. Populated by match_unmatched_orders_sweep().';
