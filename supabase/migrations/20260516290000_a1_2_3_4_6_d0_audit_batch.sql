-- ============================================================================
-- D0 audit batch — closes A1.2 + A1.3 + A1.4 + A1.6 (bot_chat 251 / 262 / 266).
--
-- A1.2 Vivid event_date sentinel:
--   1 row in vivid_orders has event_date = 2099-03-17 (Glennon Doyle Melton
--   postponed-TBD). Set event_date = NULL — the event_name suffix
--   "(Postponed - Date TBD)" preserves the original signal.
--   Note: status mapping is already correct in order_status_xref
--   (PENDING_SHIPMENT → canonical_status=accepted, is_sale_succeeded=false).
--   The 915 PENDING_SHIPMENT rows ARE accurately mapped — D0's "0 marked
--   succeeded" is the correct view since orders are pending fulfillment.
--
-- A1.3 Las Vegas Aces aq_performer_map:
--   Row exists (performer_short_id=LA780EA, name='Las Vegas Aces') but
--   tevo_performer_id IS NULL. TEvo performer 56746 is the correct mapping
--   (confirmed via performer_metadata). Populates tevo_performer_id +
--   category.
--
-- A1.4 LAFC aliases:
--   aq_performer_map has 1 LAFC row (LA94425) with tevo_performer_id NULL,
--   but the canonical name in events is "Los Angeles FC" (tevo 55771).
--   Exact-name lookup misses LAFC because the canonical row uses a
--   different variant. Fix: add aliases text[] column so each canonical
--   row carries known variants. Populate LAFC + Aces alias sets.
--
-- A1.6 RPC weather_latest fallback:
--   get_broker_event_page_v2's freshness section sets weather_latest from
--   weather_observations WHERE is_forecast=false. For upcoming events with
--   no observations yet but live forecast data, weather_latest reads NULL
--   even though forecasts are present. Add forecast fallback when obs is
--   NULL.
--
-- NOT in this batch:
--   A1.1 — already shipped via PR #178 (migration 20260516280000)
--   A1.5, A1.7 — deferred per A1's bot_chat 267 sequencing
--   #235 SEC-MED (body guards on 2 RPCs) — B1 marked "not blocking / routine";
--     JWT-email gate already protects get_broker_event_page. SECDEF
--     current_user is the function owner not caller, so §6 guard is a no-op
--     here. Acknowledged + deferred to next health-check rewrite pass.
-- ============================================================================

-- ============================================================================
-- A1.2 Vivid event_date sentinel
-- ============================================================================
UPDATE public.vivid_orders
SET event_date = NULL
WHERE event_date::date >= '2099-01-01' OR event_date::date < '1970-01-01';

-- ============================================================================
-- A1.3 + A1.4 aq_performer_map aliases column + Aces/LAFC backfill
-- ============================================================================
ALTER TABLE public.aq_performer_map
  ADD COLUMN IF NOT EXISTS aliases text[] DEFAULT '{}'::text[];

CREATE INDEX IF NOT EXISTS aq_performer_map_aliases_gin
  ON public.aq_performer_map USING gin(aliases);

COMMENT ON COLUMN public.aq_performer_map.aliases IS
  'Known alternate names for this performer. D0 A1.4 (2026-05-16): allows fuzzy match across canonical-name variants (e.g. LAFC ↔ Los Angeles FC ↔ Los Angeles Football Club). Query via name = ANY(aliases) OR lower(performer_name) = lower(name).';

-- A1.3 — Las Vegas Aces (WNBA)
UPDATE public.aq_performer_map
SET tevo_performer_id = 56746,
    category = 'Sports',
    aliases = ARRAY['Aces', 'Vegas Aces', 'LV Aces']
WHERE performer_short_id = 'LA780EA';

-- A1.4 — LAFC + aliases. Canonical TEvo performer 55771 = "Los Angeles FC".
UPDATE public.aq_performer_map
SET tevo_performer_id = 55771,
    performer_name = 'Los Angeles FC',  -- align to TEvo canonical
    category = 'Sports',
    aliases = ARRAY['LAFC', 'Los Angeles Football Club']
WHERE performer_short_id = 'LA94425';

-- ============================================================================
-- A1.6 RPC v2 — weather_latest fallback to forecast
-- ============================================================================
-- Note: only changing the freshness block; leaving everything else untouched.
-- Easier path than CREATE OR REPLACE: this migration documents the change but
-- the actual RPC edit is applied as a separate apply_migration call
-- (the full v2 body is ~250 LOC and reproducing it inline here invites drift
-- with the canonical version in migration 20260516050000_get_broker_event_page_v2.sql).
-- See migration 20260516290001 for the get_broker_event_page_v2 update.
