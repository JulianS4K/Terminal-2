-- Migration 20260515110000 · level:admin · lane:Audit/Push · writes:FK constraints on vivid_orders, tickpick_orders, seatgeek_orders + column comments · reads:- · pre:20260514190000,20260515100000
-- Cross-source order → events(id) FK declarations + internal-ID-only
-- documentation.
--
-- Operator directive 2026-05-14: "fk map against sg/evo noting ids are
-- likely internal only."
--
-- The three external order tables (vivid_orders, tickpick_orders,
-- seatgeek_orders) each carry a `tevo_event_id` column that's NULL until a
-- future cross-source matcher populates it. Declaring the FK as NOT VALID
-- means:
--   - schema visualizer now renders the cross-source web (3 new arrows)
--   - existing NULLs are accepted (NOT VALID skips the historical scan)
--   - future inserts/updates enforce the FK at row-write time
--
-- evo_orders is intentionally NOT touched here: evo's order→event link runs
-- through evo_order_items.event_id, already FK'd by PR #99
-- (20260514190000_cross_source_fk_declarations).
--
-- The COMMENT statements document which IDs are namespace-local and
-- therefore *do not* FK across sources (vivid_order_id, sg_order_id,
-- tp_order_id, productionId, listingId, brokerTicketId, orderToken,
-- sg_listing_id, etc.). This addresses operator's "ids are likely internal
-- only" note in the schema-visualizer-readable form (column comments
-- render in Studio's column tooltips).
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session). Idempotent — guards on FK
-- + COMMENT statements re-run safely.

-- ============================================================
-- FK declarations (NOT VALID — instant apply on prod)
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'vivid_orders_tevo_event_id_fkey'
      AND conrelid = 'public.vivid_orders'::regclass
  ) THEN
    ALTER TABLE public.vivid_orders
      ADD CONSTRAINT vivid_orders_tevo_event_id_fkey
      FOREIGN KEY (tevo_event_id) REFERENCES public.events(id) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'tickpick_orders_tevo_event_id_fkey'
      AND conrelid = 'public.tickpick_orders'::regclass
  ) THEN
    ALTER TABLE public.tickpick_orders
      ADD CONSTRAINT tickpick_orders_tevo_event_id_fkey
      FOREIGN KEY (tevo_event_id) REFERENCES public.events(id) NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'seatgeek_orders_tevo_event_id_fkey'
      AND conrelid = 'public.seatgeek_orders'::regclass
  ) THEN
    ALTER TABLE public.seatgeek_orders
      ADD CONSTRAINT seatgeek_orders_tevo_event_id_fkey
      FOREIGN KEY (tevo_event_id) REFERENCES public.events(id) NOT VALID;
  END IF;
END $$;

-- ============================================================
-- Internal-only ID documentation (column comments)
-- ============================================================

-- Vivid Seats — order PK + the IDs we promote out of raw_xml into the raw jsonb
COMMENT ON COLUMN public.vivid_orders.vivid_order_id IS
  'Vivid-internal order ID (XML <orderId>). Internal to vividseats.com namespace; '
  'does NOT cross-reference TEvo/SG/TickPick order IDs. No FK declared.';

COMMENT ON COLUMN public.vivid_orders.tevo_event_id IS
  'Derived TEvo events.id mapping. NULL until cross-source matcher is built '
  '(see plan zany-skipping-fox: future order→listing matcher). FK NOT VALID — '
  'existing NULLs accepted, future writes enforce.';

COMMENT ON COLUMN public.vivid_orders.raw IS
  'JSONB capture of Vivid-internal IDs not promoted to columns: orderToken, '
  'brokerTicketId, listingId, productionId, eventId, venue, notes, '
  'expectedShipDate. All Vivid-namespace-local — never FK cross-source.';

COMMENT ON COLUMN public.vivid_orders.raw_xml IS
  'Original <order>...</order> XML element preserved verbatim for audit + '
  're-parse on schema evolution.';

-- SeatGeek — all IDs are SG-namespace-local
COMMENT ON COLUMN public.seatgeek_orders.sg_order_id IS
  'SG-internal order ID. Internal to seatgeek.com namespace; no cross-source FK.';

COMMENT ON COLUMN public.seatgeek_orders.sg_event_id IS
  'SG-internal event ID. Used by SG matcher to resolve to TEvo via '
  'sg_events_canonical.tevo_event_id. SG namespace; no direct FK to events(id).';

COMMENT ON COLUMN public.seatgeek_orders.sg_listing_id IS
  'SG-internal listing ID. Used by match_listings_to_sg_tick() to resolve '
  'to TEvo ticket_group_id via listing_xref. SG namespace.';

COMMENT ON COLUMN public.seatgeek_orders.tevo_event_id IS
  'Derived TEvo events.id mapping via SG event matcher. FK NOT VALID — '
  'existing NULLs accepted, future writes enforce.';

-- TickPick — all IDs are TickPick-namespace-local
COMMENT ON COLUMN public.tickpick_orders.tp_order_id IS
  'TickPick-internal order ID. Internal to tickpick.com namespace; '
  'no cross-source FK.';

COMMENT ON COLUMN public.tickpick_orders.tevo_event_id IS
  'Derived TEvo events.id mapping. NULL until cross-source matcher is built '
  '(see plan zany-skipping-fox). FK NOT VALID.';

-- Evo (for completeness — already FK'd via evo_order_items.event_id in PR #99)
COMMENT ON COLUMN public.evo_orders.evo_order_id IS
  'TEvo-internal order ID. The PK on evo_orders. evo_order_items.event_id '
  '(FK to events.id, declared in 20260514190000) is the order→event linkage.';
