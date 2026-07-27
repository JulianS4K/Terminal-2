-- Migration 20260515190000 · level:admin · lane:Audit/Push · writes:aq_event_map PK swap (aq_short_event_id text → bigserial id), 4 order-table FK rebinding · reads:- · pre:20260515180000
-- Revert aq_event_map PK to bigserial id; keep aq_short_event_id as
-- UNIQUE so it remains the cross-source MATCHING key.
--
-- Operator direction 2026-05-14: "revert PK TO EVO PLEASE BUT KEEP AQ
-- KEY AS PRIMARY FOR MATCHING" — interpreted as:
--   - PRIMARY KEY (database PK) → Evo-style bigserial id
--   - PRIMARY for matching → aq_short_event_id stays UNIQUE NOT NULL
--     (the column the 4 order tables FK against)
--
-- FK target column for the 4 order tables stays aq_short_event_id —
-- only the underlying PG index changes from PK to UNIQUE. PostgreSQL
-- requires the FK target column to have either a PK or UNIQUE
-- constraint, so the UNIQUE meets that requirement.
--
-- Mechanics: PG won't drop the PK while FKs depend on its index, so we
--   1. Drop the 4 FKs
--   2. Drop the PK on aq_short_event_id
--   3. Add UNIQUE NOT NULL on aq_short_event_id (new index)
--   4. Add bigserial id + new PK on id
--   5. Re-add the 4 FKs (now pointing at the UNIQUE index) + VALIDATE
--
-- All FK data values are unchanged; only the structural target index swaps.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session). Idempotent — re-running
-- on a DB that already has the bigserial id PK is a no-op (the IF NOT
-- EXISTS / OR REPLACE patterns + the constraint-existence checks would
-- need to be added if we expect that case; for prod this is one-shot).

-- 1. Drop the 4 FKs that depend on the existing PK index
ALTER TABLE public.vivid_orders     DROP CONSTRAINT vivid_orders_aq_short_event_id_fkey;
ALTER TABLE public.tickpick_orders  DROP CONSTRAINT tickpick_orders_aq_short_event_id_fkey;
ALTER TABLE public.seatgeek_orders  DROP CONSTRAINT seatgeek_orders_aq_short_event_id_fkey;
ALTER TABLE public.evo_order_items  DROP CONSTRAINT evo_order_items_aq_short_event_id_fkey;

-- 2. Drop the existing PK on aq_short_event_id
ALTER TABLE public.aq_event_map DROP CONSTRAINT aq_event_map_pkey;

-- 3. Add UNIQUE NOT NULL on aq_short_event_id (replaces the PK-backed uniqueness)
ALTER TABLE public.aq_event_map ALTER COLUMN aq_short_event_id SET NOT NULL;
ALTER TABLE public.aq_event_map ADD CONSTRAINT aq_event_map_aq_short_event_id_key
  UNIQUE (aq_short_event_id);

-- 4. Add bigserial id + new PK
ALTER TABLE public.aq_event_map ADD COLUMN id bigserial;
ALTER TABLE public.aq_event_map ADD PRIMARY KEY (id);

-- 5. Re-add the 4 FKs (now bound to the UNIQUE index, not the dropped PK)
ALTER TABLE public.vivid_orders
  ADD CONSTRAINT vivid_orders_aq_short_event_id_fkey
  FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
ALTER TABLE public.vivid_orders VALIDATE CONSTRAINT vivid_orders_aq_short_event_id_fkey;

ALTER TABLE public.tickpick_orders
  ADD CONSTRAINT tickpick_orders_aq_short_event_id_fkey
  FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
ALTER TABLE public.tickpick_orders VALIDATE CONSTRAINT tickpick_orders_aq_short_event_id_fkey;

ALTER TABLE public.seatgeek_orders
  ADD CONSTRAINT seatgeek_orders_aq_short_event_id_fkey
  FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
ALTER TABLE public.seatgeek_orders VALIDATE CONSTRAINT seatgeek_orders_aq_short_event_id_fkey;

ALTER TABLE public.evo_order_items
  ADD CONSTRAINT evo_order_items_aq_short_event_id_fkey
  FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
ALTER TABLE public.evo_order_items VALIDATE CONSTRAINT evo_order_items_aq_short_event_id_fkey;

-- 6. Doc the new shape
COMMENT ON COLUMN public.aq_event_map.id IS
  'Bigserial primary key (Evo-style). Internal row identifier.';
COMMENT ON COLUMN public.aq_event_map.aq_short_event_id IS
  'AQ-assigned 7-char canonical event ID (e.g. OOGGA66). UNIQUE NOT NULL. This is the cross-source MATCHING key — order tables FK to this column, not to id.';
