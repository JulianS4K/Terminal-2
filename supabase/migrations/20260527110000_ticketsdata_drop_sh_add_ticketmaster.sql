-- 20260527110000_ticketsdata_drop_sh_add_ticketsmaster.sql
--
-- Operator directive 2026-05-27: drop StubHub (SH), add Ticketmaster (TM).
--
-- FINDINGS:
--   TicketsData DOES support platform='ticketmaster' (confirmed via live probe,
--   request_id 243713 — returned event_not_found, not "unknown platform").
--   URL format: https://www.ticketmaster.com/event/{hex-event-id}
--
-- BLOCKER for TM activation:
--   aq_event_map.tm_event_id values are 7-digit integers (TEvo internal IDs).
--   They are NOT Ticketmaster's 16-char hex URL event IDs. TM event URLs cannot
--   be constructed directly from these IDs. TM activation requires URL discovery
--   via TicketsData's /events endpoint (same path as GT/TP Phase 2).
--
-- CHANGES:
--   1. Deactivate all existing SH rows in ticketsdata_event_xref
--   2. Replace CHECK constraint: drop 'SH', add 'TM'
--   3. td_api_platform(): add 'TM' → 'ticketmaster'
--   4. td_watchlist_refresh(): remove SH upsert loop; add TM stub rows
--      (active=false, event_url=NULL — placeholder until URL discovery runs)
--   5. ticketsdata_normalize_listings(): add TM stub (returns empty; prevents
--      RAISE EXCEPTION crash when first live TM responses arrive)
--   6. Update budget notes (Phase 1 now VD-only = 160 credits/day)
--
-- BUDGET (Phase 1 revised — VD only):
--   40 events × 1 platform × 4 intervals × 1 credit = 160 credits/day < 333 ✓
--   TM activation will add ~160 more (320 total) once URLs are populated.
--
-- TM URL DISCOVERY (future migration):
--   Option A: TicketsData /events endpoint — search by name+date+venue, costs
--             1 credit per discovery call; map result td_event_url into xref.
--   Option B: SeatData sd_tm_event_id (column exists, no rows yet) — populate
--             via SeatData event-match pipeline once TM IDs flow through.
--   Option C: Manual URL entry by operator for always_on events (Knicks, etc.)
--
-- ROLLBACK:
--   UPDATE ticketsdata_event_xref SET active=true WHERE platform='SH';
--   ALTER TABLE ticketsdata_event_xref DROP CONSTRAINT ticketsdata_event_xref_platform_check;
--   ALTER TABLE ticketsdata_event_xref ADD CONSTRAINT ticketsdata_event_xref_platform_check
--     CHECK (platform IN ('SH','VD','GT','TP'));
--   (Re-run td_api_platform and watchlist_refresh from 20260527100000 to restore SH.)


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Deactivate existing SH rows
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE public.ticketsdata_event_xref
SET active = false, updated_at = now()
WHERE platform = 'SH';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Update platform CHECK constraint: replace SH with TM
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.ticketsdata_event_xref
  DROP CONSTRAINT IF EXISTS ticketsdata_event_xref_platform_check;

ALTER TABLE public.ticketsdata_event_xref
  ADD CONSTRAINT ticketsdata_event_xref_platform_check
  CHECK (platform IN ('VD','GT','TP','TM'));
-- Note: existing SH rows still exist with active=false — they are grandfathered
-- (CHECK only applies to new inserts/updates). They can be deleted in a future
-- cleanup migration once confirmed no longer needed.


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. td_api_platform() — add TM, keep SH mapping for backward compat
--    (SH rows are inactive but normalize_drain may still process in-flight requests)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_api_platform(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE p_code
    WHEN 'SH' THEN 'stubhub'         -- kept for in-flight SH drain requests
    WHEN 'VD' THEN 'vividseats'
    WHEN 'GT' THEN 'gametime'
    WHEN 'TP' THEN 'tickpick'
    WHEN 'TM' THEN 'ticketmaster'    -- NEW — confirmed supported 2026-05-27
    ELSE LOWER(p_code)
  END;
$$;

REVOKE ALL ON FUNCTION public.td_api_platform(text) FROM anon, public;
COMMENT ON FUNCTION public.td_api_platform(text) IS
  'Maps internal platform code to TicketsData API platform string. '
  'TM (ticketmaster) confirmed supported 2026-05-27 (probe req 243713). '
  'SH kept for backward compat with any in-flight drain rows.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. td_watchlist_refresh() — remove SH loop, add TM stub (active=false)
--    TM rows are registered with event_url=NULL and active=false. They will be
--    activated by a future td_tm_discover() function once valid TM hex event
--    URLs are resolved via TicketsData /events discovery.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_watchlist_refresh()
RETURNS integer   -- count of (event, platform) pairs upserted
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r         RECORD;
  v_count   int := 0;
  v_now     timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_watchlist_refresh') THEN RETURN 0; END IF;

  -- Reset enqueues_today for all xref rows (new UTC day)
  UPDATE public.ticketsdata_event_xref
  SET enqueues_today = 0, updated_at = v_now
  WHERE enqueues_today > 0;

  -- Deactivate xref rows for past events
  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND event_id IN (
      SELECT aem.vivid_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
      UNION
      SELECT aem.tm_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
    );

  -- ── VividSeats (VD) ─────────────────────────────────────────────────────
  -- Direct ID from aq_event_map.vivid_event_id → URL constructible.
  FOR r IN
    SELECT
      aem.vivid_event_id                                                 AS event_id,
      aem.aq_short_event_id,
      aem.performer,
      aem.event_name,
      sgc.sg_datetime_utc
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.vivid_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id,
      'VD',
      r.aq_short_event_id,
      'https://www.vividseats.com/production/' || r.event_id::text,
      true,
      (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
      'direct_id',
      v_now
    )
    ON CONFLICT (event_id, platform) DO UPDATE
      SET active       = true,
          always_on    = (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
          event_url    = EXCLUDED.event_url,
          updated_at   = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- ── Ticketmaster (TM) ───────────────────────────────────────────────────
  -- Register TM rows as placeholders (active=false, event_url=NULL).
  -- aq_event_map.tm_event_id is TEvo's internal ID — NOT TM's 16-char hex
  -- URL event ID. Cannot construct valid TM URLs from these integers.
  -- Activation path: run td_tm_discover() (future) after URL resolution.
  -- Operator can also manually set event_url + active=true for specific events.
  FOR r IN
    SELECT
      aem.tm_event_id                                                    AS event_id,
      aem.aq_short_event_id,
      aem.performer,
      aem.event_name,
      sgc.sg_datetime_utc
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.tm_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id,
      'TM',
      r.aq_short_event_id,
      NULL,          -- URL unknown; populated by td_tm_discover() or operator
      false,         -- inactive until URL resolved
      (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
      'pending_discovery',
      v_now
    )
    ON CONFLICT (event_id, platform) DO UPDATE
      SET always_on    = (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
          -- Do NOT overwrite event_url or active — preserve any operator-set values
          updated_at   = v_now;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_watchlist_refresh() FROM anon, public;
COMMENT ON FUNCTION public.td_watchlist_refresh() IS
  'Daily watchlist upsert for VD (active) + TM (registered, inactive pending URL discovery). '
  'SH removed 2026-05-27 per operator directive. '
  'TM URL format confirmed working on TicketsData; blocked on hex event ID resolution. '
  'Budget: 40 events × 1 VD platform × 4 intervals = 160 credits/day.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. ticketsdata_normalize_listings() — add TM stub arm
--    Returns empty rows with a NOTICE so normalize_drain doesn't crash when
--    the first real TM responses arrive. Add field paths once confirmed live.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ticketsdata_normalize_listings(
  p_platform text,
  p_content  jsonb
)
RETURNS TABLE (
  td_listing_id   text,
  section         text,
  "row"           text,
  quantity        int,
  list_price      numeric,
  price_with_fees numeric,
  is_parking      boolean,
  raw             jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  CASE p_platform

    -- ── StubHub ─────────────────────────────────────────────────────────────
    -- SH kept for any in-flight drain rows on existing resolved SH xref entries.
    WHEN 'SH' THEN
      RETURN QUERY
      SELECT
        (item->>'listingId')::text,
        item->>'section',
        item->>'row',
        (item->>'availableTickets')::int,
        (item->>'rawPrice')::numeric,
        (item->>'priceWithFees')::numeric,
        false::boolean,
        item
      FROM jsonb_array_elements(p_content->'body'->'items') AS item;

    -- ── VividSeats ───────────────────────────────────────────────────────────
    WHEN 'VD' THEN
      RETURN QUERY
      SELECT
        (offer->>'listingId')::text,
        offer->>'section',
        offer->>'row',
        (offer->>'availableTickets')::int,
        (offer->>'rawPrice')::numeric,
        (offer->>'rawPriceWithFees')::numeric,
        false::boolean,
        offer
      FROM jsonb_array_elements(p_content->'body'->'items'->'offers') AS offer;

    -- ── Gametime ─────────────────────────────────────────────────────────────
    -- Prices in CENTS — divide by 100.
    WHEN 'GT' THEN
      RETURN QUERY
      SELECT
        (item->>'listing_id')::text,
        item->>'section_name',
        item->>'row',
        (item->>'quantity')::int,
        (((item->'price'->>'prefee')::numeric)  / 100.0),
        (((item->'price'->>'total')::numeric)   / 100.0),
        (lower(COALESCE(item->>'ticket_type', '')) = 'parking')::boolean,
        item
      FROM jsonb_array_elements(p_content->'body') AS item;

    -- ── TickPick ─────────────────────────────────────────────────────────────
    WHEN 'TP' THEN
      RETURN QUERY
      SELECT
        (offer->>'listing_id')::text,
        COALESCE(offer->>'section_name', offer->>'section_id'),
        offer->>'row',
        (offer->>'quantity')::int,
        (offer->>'price')::numeric,
        (  COALESCE((offer->>'price')::numeric,                      0)
         + COALESCE((offer->'fees'->>'service')::numeric,            0)
         + COALESCE((offer->'fees'->>'facility')::numeric,           0)
         + COALESCE((offer->'fees'->>'delivery')::numeric,           0)
        ),
        COALESCE((offer->>'is_parking')::boolean, false),
        offer
      FROM jsonb_array_elements(p_content->'body'->'items'->'offers') AS offer;

    -- ── Ticketmaster (TM) — STUB ─────────────────────────────────────────────
    -- Field paths TBD — require first live 200 response to confirm body structure.
    -- Returns empty result set (0 rows); normalize_drain logs rows_inserted=0.
    -- Update this arm once a real TM 200 response is observed in net._http_response.
    -- TicketsData probe 2026-05-27 confirmed: platform accepted, quota_remaining=9961.
    -- Likely body structure (to verify): body.items[] or body.listings[]
    --   with fields: id/listingId, section, row, quantity, price, fees
    WHEN 'TM' THEN
      RAISE NOTICE 'ticketsdata_normalize_listings: TM field paths not yet confirmed — returning 0 rows. Inspect net._http_response for raw body structure.';
      RETURN;  -- empty result, no crash

    ELSE
      RAISE EXCEPTION 'ticketsdata_normalize_listings: unknown platform %', p_platform;

  END CASE;
END $$;

REVOKE ALL ON FUNCTION public.ticketsdata_normalize_listings(text, jsonb) FROM anon, public;
COMMENT ON FUNCTION public.ticketsdata_normalize_listings(text, jsonb) IS
  'Parses raw TicketsData /fetch response into normalized offer rows. '
  'TM arm is a stub — field paths TBD pending first live 200 response. '
  'SH arm retained for in-flight drain rows. '
  'VD/GT/TP body paths from D0 live tests (ticketsdata_client.py on claude/resume-d0-chat-itUGb).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Update cron_policy note for td_enqueue_peak (budget revised)
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE public.cron_policy
SET notes = 'TD enqueue peak 4x/day: noon/4pm/8pm/11pm ET; 80 pairs/fire = 40 events × VD. '
            'SH removed 2026-05-27. TM registered (inactive pending URL discovery). '
            'Budget: 40 × 1 platform × 4 intervals = 160 credits/day (was 320 with SH).',
    updated_at = now()
WHERE jobname = 'td_enqueue_peak';
