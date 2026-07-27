-- Migration 20260515180000 · level:admin · lane:Audit/Push · writes:aq_event_map (drop+recreate with aq_short_event_id PK), aq_event_map_ingest fn, 4 order-table xref columns + FKs · reads:- · pre:20260514190000,20260515110000,20260515160000
-- AQ Short Event ID is now the canonical cross-source event PK.
--
-- Operator direction 2026-05-14 (after measuring AQ-map forward-look
-- coverage Evo 84.2% / Vivid 93.5% / SG 76.7%):
--   "make AQ Short Event ID the primary key and map to that, also add AQ
--    Short Event ID to our sql table and make it primary key"
--
-- Interpretation:
--   - aq_event_map.aq_short_event_id is the PK on the reference table
--   - Each order table (vivid_orders, tickpick_orders, seatgeek_orders,
--     evo_order_items) gets an aq_short_event_id column + FK to
--     aq_event_map. The column is NOT the PK on order tables (orders
--     aren't 1:1 with events; they keep their existing PKs).
--   - This replaces the earlier idea of bridging everything through
--     events.id (TEvo) — AQ short IDs are operator-curated and have
--     no TEvo-ingest-window gap.
--
-- The earlier aq_event_map (created earlier this session with a bigserial
-- PK) is DROPPED and recreated. Only 30 min old, no other table FKs into
-- it yet.
--
-- 5,921 rows kept (out of 6,159 from the xlsx). The 238 rows without a
-- short ID are dropped because they have no external IDs either — AQ
-- knew the event existed but hadn't classified it.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session) in two steps:
--   1. apply_migration(aq_event_map_short_id_pk_and_xref_columns) — schema
--   2. execute_sql with the UPDATEs + VALIDATE — population
-- This file consolidates both into a single replayable artifact.

-- 1. Drop the legacy aq_event_map + ingest fn (CASCADE clears any FKs)
DROP TABLE IF EXISTS public.aq_event_map CASCADE;
DROP FUNCTION IF EXISTS public.aq_event_map_ingest(jsonb);

-- 2. Recreate with aq_short_event_id as PK + UUID backup
CREATE TABLE public.aq_event_map (
  aq_short_event_id   text        PRIMARY KEY,    -- 7-char operator-curated short code
  event_id_uuid       uuid,                       -- AQ-internal UUID (backup identifier)
  event_name          text,
  venue_name          text,
  event_date          timestamp,
  city                text,
  state               text,
  performer           text,
  category            text,
  vivid_event_id      bigint,
  sh_event_id         bigint,
  sg_event_id         bigint,
  tm_event_id         bigint,
  tnow_production_id  text,
  imported_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_aq_event_map_uuid     ON public.aq_event_map(event_id_uuid)     WHERE event_id_uuid IS NOT NULL;
CREATE INDEX idx_aq_event_map_vivid    ON public.aq_event_map(vivid_event_id)    WHERE vivid_event_id IS NOT NULL;
CREATE INDEX idx_aq_event_map_sg       ON public.aq_event_map(sg_event_id)       WHERE sg_event_id IS NOT NULL;
CREATE INDEX idx_aq_event_map_sh       ON public.aq_event_map(sh_event_id)       WHERE sh_event_id IS NOT NULL;
CREATE INDEX idx_aq_event_map_tm       ON public.aq_event_map(tm_event_id)       WHERE tm_event_id IS NOT NULL;
CREATE INDEX idx_aq_event_map_date     ON public.aq_event_map(event_date);
CREATE INDEX idx_aq_event_map_venue    ON public.aq_event_map(venue_name, event_date);

COMMENT ON TABLE public.aq_event_map IS
  'Operator-curated cross-source event map from AQ/Automatiq. aq_short_event_id (7-char) is the canonical primary key; every order/listing table FKs back to this. Imported 2026-05-14 from kjUntitled spreadsheet.xlsx. 5,921 rows with non-null short IDs (238 unclassified rows dropped).';

COMMENT ON COLUMN public.aq_event_map.aq_short_event_id IS
  'AQ-assigned 7-char canonical event ID (e.g. OOGGA66). Primary key — the cross-source bridge other tables FK to.';

-- RLS lockdown
ALTER TABLE public.aq_event_map ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_only ON public.aq_event_map
  FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);

-- 3. Ingest fn (idempotent UPSERT by aq_short_event_id, scrubs non-numeric chars from IDs)
CREATE OR REPLACE FUNCTION public.aq_event_map_ingest(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_inserted int;
BEGIN
  WITH src AS (SELECT r FROM jsonb_array_elements(p_rows) AS r),
  ins AS (
    INSERT INTO public.aq_event_map (
      aq_short_event_id, event_id_uuid,
      event_name, venue_name, event_date, city, state, performer, category,
      vivid_event_id, sh_event_id, sg_event_id, tm_event_id, tnow_production_id
    )
    SELECT
      NULLIF(r->>'aq_short_event_id',''),
      NULLIF(r->>'event_id_uuid','')::uuid,
      NULLIF(r->>'event_name',''),
      NULLIF(r->>'venue_name',''),
      NULLIF(r->>'event_date','')::timestamp,
      NULLIF(r->>'city',''),
      NULLIF(r->>'state',''),
      NULLIF(r->>'performer',''),
      NULLIF(r->>'category',''),
      NULLIF(regexp_replace(coalesce(r->>'vivid_event_id',''),  '[^0-9]', '', 'g'), '')::bigint,
      NULLIF(regexp_replace(coalesce(r->>'sh_event_id',''),     '[^0-9]', '', 'g'), '')::bigint,
      NULLIF(regexp_replace(coalesce(r->>'sg_event_id',''),     '[^0-9]', '', 'g'), '')::bigint,
      NULLIF(regexp_replace(coalesce(r->>'tm_event_id',''),     '[^0-9]', '', 'g'), '')::bigint,
      NULLIF(r->>'tnow_production_id','')
    FROM src
    WHERE NULLIF(r->>'aq_short_event_id','') IS NOT NULL
    ON CONFLICT (aq_short_event_id) DO UPDATE SET
      event_id_uuid      = EXCLUDED.event_id_uuid,
      event_name         = EXCLUDED.event_name,
      venue_name         = EXCLUDED.venue_name,
      event_date         = EXCLUDED.event_date,
      city               = EXCLUDED.city,
      state              = EXCLUDED.state,
      performer          = EXCLUDED.performer,
      category           = EXCLUDED.category,
      vivid_event_id     = EXCLUDED.vivid_event_id,
      sh_event_id        = EXCLUDED.sh_event_id,
      sg_event_id        = EXCLUDED.sg_event_id,
      tm_event_id        = EXCLUDED.tm_event_id,
      tnow_production_id = EXCLUDED.tnow_production_id
    RETURNING 1
  )
  SELECT count(*) INTO v_inserted FROM ins;
  RETURN v_inserted;
END $$;

-- 4. Add aq_short_event_id columns + NOT VALID FKs on the 4 order tables
ALTER TABLE public.vivid_orders     ADD COLUMN IF NOT EXISTS aq_short_event_id text;
ALTER TABLE public.tickpick_orders  ADD COLUMN IF NOT EXISTS aq_short_event_id text;
ALTER TABLE public.seatgeek_orders  ADD COLUMN IF NOT EXISTS aq_short_event_id text;
ALTER TABLE public.evo_order_items  ADD COLUMN IF NOT EXISTS aq_short_event_id text;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='vivid_orders_aq_short_event_id_fkey') THEN
    ALTER TABLE public.vivid_orders
      ADD CONSTRAINT vivid_orders_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='tickpick_orders_aq_short_event_id_fkey') THEN
    ALTER TABLE public.tickpick_orders
      ADD CONSTRAINT tickpick_orders_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='seatgeek_orders_aq_short_event_id_fkey') THEN
    ALTER TABLE public.seatgeek_orders
      ADD CONSTRAINT seatgeek_orders_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='evo_order_items_aq_short_event_id_fkey') THEN
    ALTER TABLE public.evo_order_items
      ADD CONSTRAINT evo_order_items_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
  END IF;
END $$;

COMMENT ON COLUMN public.vivid_orders.aq_short_event_id IS
  'Canonical cross-source event ID via aq_event_map. Populated when raw.productionId matches aq_event_map.vivid_event_id. NULL if event not in AQ map.';
COMMENT ON COLUMN public.tickpick_orders.aq_short_event_id IS
  'Canonical cross-source event ID via aq_event_map. Populated by venue+date lookup (TickPick has no direct AQ-side ID column). NULL if event not in AQ map.';
COMMENT ON COLUMN public.seatgeek_orders.aq_short_event_id IS
  'Canonical cross-source event ID via aq_event_map. Populated when sg_event_id matches aq_event_map.sg_event_id.';
COMMENT ON COLUMN public.evo_order_items.aq_short_event_id IS
  'Canonical cross-source event ID via aq_event_map. Populated by events.venue_name+occurs_at lookup against aq_event_map.';

-- 5. NOTE: aq_event_map data load + order-table population are NOT in this migration
-- because they require the JSON payload from the xlsx (5,921 rows). The data was
-- ingested via the PostgREST RPC during this session; re-running this migration
-- only recreates the empty schema + FKs.
--
-- To re-load on a fresh database:
--   1. Re-export the xlsx via scripts/extract_aq_event_map.py (TBD; for now, ad-hoc)
--   2. POST chunks of 500 rows each to /rest/v1/rpc/aq_event_map_ingest
--   3. Run the UPDATE statements below to backfill xref on existing order rows
--   4. ALTER TABLE ... VALIDATE CONSTRAINT for each of the 4 FKs

-- Population UPDATEs (idempotent — only updates rows where aq_short_event_id IS NULL)

UPDATE public.vivid_orders v
   SET aq_short_event_id = aq.aq_short_event_id
  FROM public.aq_event_map aq
 WHERE aq.vivid_event_id = (v.raw->>'productionId')::bigint
   AND v.aq_short_event_id IS NULL;

UPDATE public.seatgeek_orders o
   SET aq_short_event_id = aq.aq_short_event_id
  FROM public.aq_event_map aq
 WHERE aq.sg_event_id = o.sg_event_id
   AND o.aq_short_event_id IS NULL;

WITH evo_match AS (
  SELECT DISTINCT ON (i.id) i.id, aq.aq_short_event_id
  FROM public.evo_order_items i
  JOIN public.events e ON e.id = i.event_id
  JOIN public.aq_event_map aq
    ON lower(trim(aq.venue_name)) = lower(trim(e.venue_name))
   AND aq.event_date::timestamptz
       BETWEEN e.occurs_at_local::timestamptz - interval '6 hours'
           AND e.occurs_at_local::timestamptz + interval '6 hours'
  ORDER BY i.id, abs(EXTRACT(epoch FROM (aq.event_date::timestamptz - e.occurs_at_local::timestamptz)))
)
UPDATE public.evo_order_items i
   SET aq_short_event_id = em.aq_short_event_id
  FROM evo_match em
 WHERE i.id = em.id
   AND i.aq_short_event_id IS NULL;

WITH tp_match AS (
  SELECT DISTINCT ON (t.tp_order_id) t.tp_order_id, aq.aq_short_event_id
  FROM public.tickpick_orders t
  JOIN public.aq_event_map aq
    ON lower(trim(aq.venue_name)) = lower(trim(t.raw->'venue'->>'name'))
   AND aq.event_date::timestamptz
       BETWEEN (t.raw->>'event_date_utc')::timestamptz - interval '6 hours'
           AND (t.raw->>'event_date_utc')::timestamptz + interval '6 hours'
  WHERE t.raw->'venue'->>'name' IS NOT NULL
    AND t.raw->>'event_date_utc' IS NOT NULL
  ORDER BY t.tp_order_id, abs(EXTRACT(epoch FROM (aq.event_date::timestamptz - (t.raw->>'event_date_utc')::timestamptz)))
)
UPDATE public.tickpick_orders t
   SET aq_short_event_id = tpm.aq_short_event_id
  FROM tp_match tpm
 WHERE t.tp_order_id = tpm.tp_order_id
   AND t.aq_short_event_id IS NULL;

-- Validate the 4 FKs
ALTER TABLE public.vivid_orders    VALIDATE CONSTRAINT vivid_orders_aq_short_event_id_fkey;
ALTER TABLE public.tickpick_orders VALIDATE CONSTRAINT tickpick_orders_aq_short_event_id_fkey;
ALTER TABLE public.seatgeek_orders VALIDATE CONSTRAINT seatgeek_orders_aq_short_event_id_fkey;
ALTER TABLE public.evo_order_items VALIDATE CONSTRAINT evo_order_items_aq_short_event_id_fkey;
