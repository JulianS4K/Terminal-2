-- Migration 20260515160000 · level:admin · lane:Audit/Push · writes:public.tickpick_orders (add matcher cols + Tier-1 UPDATE) + VALIDATE FK · reads:venue_assets, events · pre:20260515110000,20260515150000
-- TickPick → TEvo event mapping v1 (coord + UTC datetime, Tier-1 only).
--
-- Operator directive 2026-05-14 after the first Apps Script sync landed
-- 909 TickPick orders: "test if [coords + datetime] will help map future
-- events between tickpick and evo … do it. map fk to orders d2 project
-- for later also."
--
-- Empirical results from the 908 CONFIRMED orders (1 REJECTED skipped):
--   • Tier 1 (≤500m, ≤60min):  176 hits / 19.4%   ← this migration applies
--   • Tier 2 (≤1500m, ≤60min):   1 hit  /  0.1%
--   • Tier 3 (≤5000m, ≤240min):  5 hits /  0.6%
--   • Venue mapped, no event: 552 / 60.8%  (TEvo ingest gap — auto-recovers)
--   • Venue not in tevo:      174 / 19.2%  (candidates for geocode_queue)
--
-- TickPick is the easiest cross-source to match because it provides
-- venue.latitude/longitude AND event_date_utc in clean ISO 8601 directly
-- in the order payload — no geocode step needed. Vivid (free-text venue
-- only) and TickPick differ here; the future v2 matcher will geocode
-- Vivid venue strings to produce comparable coords.
--
-- Changes:
-- 1. ADD provenance columns to tickpick_orders:
--      matched_via      text       — 'coord_datetime_tier1' | ...
--      match_confidence numeric(3,2)
--      matched_at       timestamptz
-- 2. UPDATE 176 Tier-1 matches: populate tevo_event_id + provenance
-- 3. VALIDATE the tickpick_orders_tevo_event_id_fkey constraint (was
--    declared NOT VALID by PR #99 / 20260514190000; now safe to enforce
--    on existing rows since the 176 matches reference real events and
--    the 733 unmatched rows leave the column NULL).
--
-- D2 lane note: `unified_orders` view reads tickpick_orders.tevo_event_id
-- and joins against events(id). After this migration, 176/909 TickPick
-- rows show their TEvo linkage in the dashboard immediately. The
-- remaining 733 stay NULL until TEvo's event ingest catches up (rerunning
-- this matcher periodically picks them up automatically).
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session). Idempotent — matched_via
-- check on UPDATE prevents double-application.

-- 1. Provenance columns
ALTER TABLE public.tickpick_orders
  ADD COLUMN IF NOT EXISTS matched_via      text,
  ADD COLUMN IF NOT EXISTS match_confidence numeric(3,2),
  ADD COLUMN IF NOT EXISTS matched_at       timestamptz;

COMMENT ON COLUMN public.tickpick_orders.matched_via IS
  'Method that populated tevo_event_id. Values: '
  '`coord_datetime_tier1` (haversine ≤500m + |Δt| ≤60min, conf 0.95). '
  'NULL when tevo_event_id is also NULL. Future v2 matcher may add '
  'tier2/tier3 / fuzzy name tiers.';

COMMENT ON COLUMN public.tickpick_orders.match_confidence IS
  '0.00–1.00 confidence score assigned by the matcher. '
  '0.95 for tier1_high coord+datetime matches.';

COMMENT ON COLUMN public.tickpick_orders.matched_at IS
  'When the matcher last assigned tevo_event_id. Useful for re-run sweeps.';

-- 2. Tier-1 UPDATE: 176 rows (idempotent — only updates rows that haven't
-- been matched yet, so re-applying this migration after a fresh sync is safe)
WITH src AS (
  SELECT
    tp_order_id,
    (raw->>'event_date_utc')::timestamptz AS tp_dt_utc,
    (raw->'venue'->>'latitude')::numeric  AS tp_lat,
    (raw->'venue'->>'longitude')::numeric AS tp_lon
  FROM public.tickpick_orders
  WHERE order_status = 'CONFIRMED'
    AND tevo_event_id IS NULL                    -- skip already-matched
    AND raw->'venue'->>'latitude' IS NOT NULL
    AND raw->>'event_date_utc' IS NOT NULL
),
matched AS (
  SELECT DISTINCT ON (s.tp_order_id)
    s.tp_order_id,
    e.id  AS tevo_event_id,
    (2 * 6371000 * asin(sqrt(
       power(sin(radians((va.latitude - s.tp_lat)/2)), 2)
       + cos(radians(s.tp_lat)) * cos(radians(va.latitude))
         * power(sin(radians((va.longitude - s.tp_lon)/2)), 2))))::int AS dist_m,
    abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - s.tp_dt_utc))/60)::int AS time_diff_min
  FROM src s
  JOIN public.venue_assets va
    ON va.latitude  BETWEEN s.tp_lat - 0.02 AND s.tp_lat + 0.02
   AND va.longitude BETWEEN s.tp_lon - 0.03 AND s.tp_lon + 0.03
  JOIN public.events e
    ON e.venue_id = va.tevo_venue_id
   AND e.occurs_at_local::timestamptz
       BETWEEN s.tp_dt_utc - interval '60 minutes'
           AND s.tp_dt_utc + interval '60 minutes'
  ORDER BY s.tp_order_id,
           -- closest match wins when multiple candidates
           (2 * 6371000 * asin(sqrt(
              power(sin(radians((va.latitude - s.tp_lat)/2)), 2)
              + cos(radians(s.tp_lat)) * cos(radians(va.latitude))
                * power(sin(radians((va.longitude - s.tp_lon)/2)), 2)))),
           abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - s.tp_dt_utc)))
)
UPDATE public.tickpick_orders t
   SET tevo_event_id    = m.tevo_event_id,
       matched_via      = 'coord_datetime_tier1',
       match_confidence = 0.95,
       matched_at       = now()
  FROM matched m
 WHERE t.tp_order_id = m.tp_order_id
   AND m.dist_m       <= 500
   AND m.time_diff_min <= 60;

-- 3. Validate the FK now that 176 rows reference real events.id values.
-- Existing NULL tevo_event_ids (733 rows) satisfy the FK trivially.
-- VALIDATE is fast on a 909-row table (microseconds).
ALTER TABLE public.tickpick_orders
  VALIDATE CONSTRAINT tickpick_orders_tevo_event_id_fkey;
