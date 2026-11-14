-- Migration 20261102220000 · level:data-collection · lane:A1 (AXS ingest) · writes:axs_event_snapshots(+cols, trigger),axs_snapshot_ga_summary()(new) · reads:axs_event_snapshots.raw · pre:20261102210000
--
-- ============================================================================
-- General-admission AXS events (operator 2026-11-02: Knockdown Center / LCD Soundsystem is GA;
-- "look for ticket quantity also for GA pulls").
--
-- A GA event has no seat map: onsale.flow = 'BEST_AVAILABLE', sections / seats empty, so
-- axs_ingest_snapshot (seat-based) stores 0 listings and no prices. What AXS does return, per
-- price level in raw.price_points (verified on event 1636873, LCD Soundsystem, Knockdown Center):
--   face 80.00 + fees 21.29 = all_in 101.29, sold_out false, availability 4
--   and groups[].ticket_qty {min 1, max 4} — availability equals the per-order maximum, so it reads
--   as "at least 4 left", not the remaining stock. raw.inventory.offer_search was empty.
-- AXS exposes no larger GA count to a reader; probing it would mean cart holds, which RULE 2 forbids.
--
-- WHAT THIS STORES (BEFORE INSERT / UPDATE OF raw trigger on axs_event_snapshots)
--   sale_flow            onsale.flow (BEST_AVAILABLE = GA, PICK_A_SEAT_* = reserved)
--   ga_price_levels      admission price levels only (price_points of the onsale offer — add-ons
--                        such as parking and shuttles, e.g. a $2.23 Red Rocks item, are left out):
--                        title, face, fees, all_in, availability, sold_out, price_level_id
--   ga_face_min / ga_all_in_min (levels still on sale), ga_available (sum over levels), ga_order_max,
--   ga_available_capped  true when every level shows availability >= the order maximum
--                        (count is a floor, not stock), ga_sold_out (every level sold out)
--   For GA (BEST_AVAILABLE) snapshots with no seat prices, price_min / price_max / getin are filled
--   from the admission face values. Reserved-seat snapshots keep their seat-derived prices.
-- Backfill: the latest snapshot of every tracked AXS event is re-run through the trigger.
-- Rollback: DROP TRIGGER axs_snapshot_ga_summary ON axs_event_snapshots;
--   DROP FUNCTION axs_snapshot_ga_summary(); ALTER TABLE axs_event_snapshots DROP COLUMN sale_flow,
--   DROP COLUMN ga_price_levels, DROP COLUMN ga_face_min, DROP COLUMN ga_all_in_min,
--   DROP COLUMN ga_available, DROP COLUMN ga_order_max, DROP COLUMN ga_available_capped, DROP COLUMN ga_sold_out;
-- ============================================================================

ALTER TABLE public.axs_event_snapshots
  ADD COLUMN IF NOT EXISTS sale_flow           text,
  ADD COLUMN IF NOT EXISTS ga_price_levels     jsonb,
  ADD COLUMN IF NOT EXISTS ga_face_min         numeric,
  ADD COLUMN IF NOT EXISTS ga_all_in_min       numeric,
  ADD COLUMN IF NOT EXISTS ga_available        integer,
  ADD COLUMN IF NOT EXISTS ga_order_max        integer,
  ADD COLUMN IF NOT EXISTS ga_available_capped boolean,
  ADD COLUMN IF NOT EXISTS ga_sold_out         boolean;

CREATE OR REPLACE FUNCTION public.axs_snapshot_ga_summary()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_offer  text;
  v_levels jsonb;
BEGIN
  IF NEW.raw IS NULL OR jsonb_typeof(NEW.raw) <> 'object' THEN
    RETURN NEW;
  END IF;
  NEW.sale_flow := NEW.raw->'onsale'->>'flow';
  IF jsonb_typeof(NEW.raw->'price_points') IS DISTINCT FROM 'array' THEN
    RETURN NEW;
  END IF;
  v_offer := NEW.raw->'onsale'->>'offer_id';

  SELECT jsonb_agg(jsonb_build_object(
           'title', p->>'title',
           'price_level_id', p->>'price_level_id',
           'offer_id', p->>'offer_id',
           'face', (p->'pricing'->>'face')::numeric,
           'fees', (p->'pricing'->>'fees_total')::numeric,
           'all_in', (p->'pricing'->>'all_in')::numeric,
           'availability', CASE jsonb_typeof(p->'availability')
                             WHEN 'number' THEN (p->>'availability')::int
                             WHEN 'object' THEN (p->'availability'->>'amount')::int END,
           'sold_out', (p->>'sold_out')::boolean)
         ORDER BY (p->'pricing'->>'face')::numeric)
    INTO v_levels
    FROM jsonb_array_elements(NEW.raw->'price_points') p
   WHERE (v_offer IS NULL OR p->>'offer_id' = v_offer)
     AND (p->'pricing'->>'face') ~ '^[0-9.]+$';

  NEW.ga_price_levels := v_levels;
  IF v_levels IS NULL THEN
    RETURN NEW;
  END IF;

  NEW.ga_order_max := (SELECT max((g->'ticket_qty'->>'max')::int)
                         FROM jsonb_array_elements(CASE WHEN jsonb_typeof(NEW.raw->'groups') = 'array'
                                                        THEN NEW.raw->'groups' ELSE '[]'::jsonb END) g
                        WHERE (g->'ticket_qty'->>'max') ~ '^\d+$');
  SELECT min((l->>'face')::numeric) FILTER (WHERE NOT coalesce((l->>'sold_out')::boolean, false)),
         min((l->>'all_in')::numeric) FILTER (WHERE NOT coalesce((l->>'sold_out')::boolean, false)),
         sum((l->>'availability')::int),
         bool_and(coalesce((l->>'sold_out')::boolean, false)),
         CASE WHEN NEW.ga_order_max IS NULL THEN NULL
              ELSE bool_and(coalesce((l->>'availability')::int, 0) >= NEW.ga_order_max) END
    INTO NEW.ga_face_min, NEW.ga_all_in_min, NEW.ga_available, NEW.ga_sold_out, NEW.ga_available_capped
    FROM jsonb_array_elements(v_levels) l;

  IF NEW.sale_flow = 'BEST_AVAILABLE' AND NEW.getin IS NULL THEN
    NEW.getin     := NEW.ga_face_min;
    NEW.price_min := coalesce(NEW.price_min, NEW.ga_face_min);
    NEW.price_max := coalesce(NEW.price_max, (SELECT max((l->>'face')::numeric) FROM jsonb_array_elements(v_levels) l));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.axs_snapshot_ga_summary() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS axs_snapshot_ga_summary ON public.axs_event_snapshots;
CREATE TRIGGER axs_snapshot_ga_summary
  BEFORE INSERT OR UPDATE OF raw ON public.axs_event_snapshots
  FOR EACH ROW EXECUTE FUNCTION public.axs_snapshot_ga_summary();

-- backfill the latest snapshot of every tracked AXS event
UPDATE public.axs_event_snapshots s SET raw = s.raw
  FROM public.axs_events a WHERE a.last_snapshot_id = s.id;
