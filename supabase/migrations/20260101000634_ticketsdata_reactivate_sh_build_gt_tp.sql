-- 20260527120000_ticketsdata_reactivate_sh_build_gt_tp.sql
--
-- Operator directive 2026-05-27: reactivate StubHub (SH), build GameTime (GT)
-- and TickPick (TP) infrastructure.
--
-- CONFIRMED SH RESPONSE STRUCTURE (live probe req 243861, 2026-05-27):
--   body.items[]: listingId (int), section, row, availableTickets (int),
--                 rawPrice (numeric), price (str "$14"), dealScore,
--                 splitsAvailable, ticketClassName, notes[]
--   CRITICAL: No priceWithFees field exists. Current normalizer had
--   (item->>'priceWithFees')::numeric returning NULL for every row. Fixed to rawPrice.
--
-- GT/TP URL DISCOVERY STATUS (2026-05-27):
--   GT: /events endpoint returns 500 "Too many requests or invalid URL" for all
--       performer_url and venue_url formats tried. Rate-limit or URL mismatch.
--   TP: /events endpoint returns {"initial_fetch_failed": true} for all tried formats.
--       TickPick event discovery pages require JS rendering not supported by TD scraper.
--   Both platforms: /fetch endpoint works when given a valid event URL (confirmed by D0).
--   Resolution options:
--     A. Manual operator URL entry for specific events
--     B. Future /events retry with different URL format patterns
--     C. /match endpoint (Pro plan only, 12 cr/call — deferred)
--   For now: GT/TP registered as inactive stubs (event_url=NULL, active=false).
--   Operator can manually set event_url + active=true for specific events.
--
-- CHANGES:
--   1. Restore SH to CHECK constraint: (SH, VD, GT, TP, TM)
--   2. td_watchlist_refresh(): restore SH loop; add GT/TP stub loops (inactive,
--      event_url=NULL, match_method='pending_discovery', event_id=sg_event_id)
--   3. ticketsdata_normalize_listings(): fix SH arm (rawPrice instead of priceWithFees);
--      add GT/TP stubs so normalize_drain doesn't crash on future live responses
--   4. td_pending_sweep(): add GT/TP deactivation (platform-scoped, uses sg_event_id)
--   5. Update cron_policy notes
--
-- GT/TP EVENT_ID CONVENTION:
--   aq_event_map has no GT/TP-specific ID columns (only sh_event_id, vivid_event_id,
--   tm_event_id). GT/TP xref rows use sg_event_id (bigint) as event_id.
--   Namespace collision risk: low (SG IDs ~5M, SH IDs ~100M+, VD IDs ~5M).
--   Deactivation queries are platform-scoped to avoid cross-namespace contamination.
--
-- BUDGET (Phase 1 with SH + VD active):
--   40 events × 2 platforms × 4 intervals × 1 credit = 320 credits/day < 333 ✓
--   GT/TP activation: +320 credits/day when URLs resolved. Will require plan
--   monitoring or phased activation to stay under 333/day cap.
--   Note: Activating both SH+VD+GT+TP simultaneously would be ~640/day > cap.
--   Operator must either upgrade plan or activate GT/TP in rotation with SH/VD.
--
-- ROLLBACK:
--   -- Remove SH again:
--   UPDATE ticketsdata_event_xref SET active=false WHERE platform='SH';
--   ALTER TABLE ticketsdata_event_xref DROP CONSTRAINT ticketsdata_event_xref_platform_check;
--   ALTER TABLE ticketsdata_event_xref ADD CONSTRAINT ticketsdata_event_xref_platform_check
--     CHECK (platform IN ('VD','GT','TP','TM'));
--   -- Re-run td_watchlist_refresh, ticketsdata_normalize_listings, td_pending_sweep from 110000


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Restore SH to CHECK constraint: (SH, VD, GT, TP, TM)
--    GT/TP were already added in 20260527110000. SH was dropped; restore it.
--    Note: ticketsdata_event_xref had no SH rows when 110000 was applied
--    (td_watchlist_refresh hadn't yet run), so the constraint change was clean.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.ticketsdata_event_xref
  DROP CONSTRAINT IF EXISTS ticketsdata_event_xref_platform_check;

ALTER TABLE public.ticketsdata_event_xref
  ADD CONSTRAINT ticketsdata_event_xref_platform_check
  CHECK (platform IN ('SH','VD','GT','TP','TM'));


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. td_api_platform() — ensure TM is still present (was added in 110000)
--    SH was preserved for backward compat in 110000; confirming here.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_api_platform(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE p_code
    WHEN 'SH' THEN 'stubhub'
    WHEN 'VD' THEN 'vividseats'
    WHEN 'GT' THEN 'gametime'
    WHEN 'TP' THEN 'tickpick'
    WHEN 'TM' THEN 'ticketmaster'
    ELSE LOWER(p_code)
  END;
$$;

REVOKE ALL ON FUNCTION public.td_api_platform(text) FROM anon, public;
COMMENT ON FUNCTION public.td_api_platform(text) IS
  'Maps internal platform code to TicketsData API platform string. '
  'SH/VD confirmed working 2026-05-27. TM confirmed supported (probe req 243713). '
  'GT/TP registered but blocked on URL discovery (see migration header).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. td_watchlist_refresh() — full rebuild:
--      SH restored (direct URL from sh_event_id)
--      VD kept (direct URL from vivid_event_id)
--      GT stub added (event_url=NULL, active=false, event_id=sg_event_id)
--      TP stub added (event_url=NULL, active=false, event_id=sg_event_id)
--      TM stub kept from 110000 (event_url=NULL, active=false, event_id=tm_event_id)
--    Deactivation is platform-scoped to avoid cross-namespace ID collisions.
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

  -- ── Deactivate past events — platform-scoped to avoid cross-namespace collisions ──
  -- SH: keyed by sh_event_id
  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND platform = 'SH'
    AND event_id IN (
      SELECT aem.sh_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
        AND aem.sh_event_id IS NOT NULL
    );

  -- VD: keyed by vivid_event_id
  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND platform = 'VD'
    AND event_id IN (
      SELECT aem.vivid_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
        AND aem.vivid_event_id IS NOT NULL
    );

  -- TM: keyed by tm_event_id (TEvo internal ID)
  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND platform = 'TM'
    AND event_id IN (
      SELECT aem.tm_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
        AND aem.tm_event_id IS NOT NULL
    );

  -- GT + TP: keyed by sg_event_id (no platform-specific ID column for these)
  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND platform IN ('GT', 'TP')
    AND event_id IN (
      SELECT sgc.sg_event_id
      FROM public.sg_events_canonical sgc
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
    );

  -- ── StubHub (SH) — direct ID from aq_event_map.sh_event_id ─────────────────
  FOR r IN
    SELECT
      aem.sh_event_id                                                    AS event_id,
      aem.aq_short_event_id,
      aem.performer,
      aem.event_name,
      sgc.sg_datetime_utc
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.sh_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id,
      'SH',
      r.aq_short_event_id,
      'https://www.stubhub.com/x/event/' || r.event_id::text || '/',
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

  -- ── VividSeats (VD) — direct ID from aq_event_map.vivid_event_id ────────────
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

  -- ── GameTime (GT) — stub: no GT event ID in aq_event_map ────────────────────
  -- Uses sg_event_id as event_id (stable canonical internal key).
  -- Registered active=false, event_url=NULL until URL discovery succeeds.
  -- Operator can manually SET event_url='https://gametime.co/events/{id}' + active=true.
  -- ON CONFLICT does NOT overwrite event_url or active — preserves operator edits.
  FOR r IN
    SELECT
      sgc.sg_event_id                                                    AS event_id,
      aem.aq_short_event_id,
      aem.performer,
      aem.event_name,
      sgc.sg_datetime_utc
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id,
      'GT',
      r.aq_short_event_id,
      NULL,   -- populated by operator or future td_gt_discover()
      false,  -- inactive until URL resolved
      (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
      'pending_discovery',
      v_now
    )
    ON CONFLICT (event_id, platform) DO UPDATE
      SET always_on    = (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
          -- Preserve event_url and active — operator may have set these manually
          updated_at   = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- ── TickPick (TP) — stub: same pattern as GT ─────────────────────────────────
  FOR r IN
    SELECT
      sgc.sg_event_id                                                    AS event_id,
      aem.aq_short_event_id,
      aem.performer,
      aem.event_name,
      sgc.sg_datetime_utc
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id,
      'TP',
      r.aq_short_event_id,
      NULL,
      false,
      (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
      'pending_discovery',
      v_now
    )
    ON CONFLICT (event_id, platform) DO UPDATE
      SET always_on    = (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
          updated_at   = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- ── Ticketmaster (TM) — stub from 110000 ─────────────────────────────────────
  -- tm_event_id is TEvo internal ID, NOT TM's 16-char hex URL event ID.
  -- Cannot construct valid TM URLs from these integers.
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
      NULL,
      false,
      (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
      'pending_discovery',
      v_now
    )
    ON CONFLICT (event_id, platform) DO UPDATE
      SET always_on    = (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
          updated_at   = v_now;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_watchlist_refresh() FROM anon, public;
COMMENT ON FUNCTION public.td_watchlist_refresh() IS
  'Daily watchlist upsert: SH+VD (active, direct_id); GT+TP+TM (inactive stubs, pending_discovery). '
  'GT/TP use sg_event_id as event_id (no GT/TP ID column in aq_event_map). '
  'Platform-scoped deactivation avoids cross-namespace ID collision. '
  'ON CONFLICT preserves operator-set event_url/active for stub platforms. '
  'Budget: SH+VD = 40×2×4 = 320 credits/day. GT/TP: ~+320 when activated.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ticketsdata_normalize_listings() — full rebuild:
--      SH arm: FIXED — (item->>'rawPrice') replaces broken (item->>'priceWithFees')
--        priceWithFees does not exist in real SH responses (confirmed req 243861).
--        rawPrice is the ticket price. is_parking inferred from ticketClassName.
--      VD arm: unchanged from 20260527050000 (D0-confirmed body paths)
--      GT arm: unchanged — real implementation for when URLs activate
--      TP arm: unchanged — real implementation for when URLs activate
--      TM arm: stub from 110000 — RAISE NOTICE + RETURN empty
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
    -- Confirmed response (req 243861 2026-05-27):
    --   body.items[]: listingId(int), section, row, availableTickets(int),
    --                 rawPrice(numeric), price(str), dealScore, ticketClassName
    -- FIXED: priceWithFees does not exist → use rawPrice for both price columns.
    -- is_parking: inferred from ticketClassName (SH doesn't have a flag field).
    WHEN 'SH' THEN
      RETURN QUERY
      SELECT
        (item->>'listingId')::text,
        item->>'section',
        item->>'row',
        (item->>'availableTickets')::int,
        (item->>'rawPrice')::numeric,
        (item->>'rawPrice')::numeric,   -- no priceWithFees in SH response; rawPrice IS the price
        (lower(COALESCE(item->>'ticketClassName', '')) LIKE '%parking%')::boolean,
        item
      FROM jsonb_array_elements(p_content->'body'->'items') AS item;

    -- ── VividSeats ───────────────────────────────────────────────────────────
    -- D0-confirmed paths (branch claude/resume-d0-chat-itUGb):
    --   body = {status_code, event_id, items: {…, offers: []}}
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

    -- ── GameTime ─────────────────────────────────────────────────────────────
    -- D0-confirmed paths: body is a direct array.
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
    -- D0-confirmed paths: body = {status_code, event_id, items: {…, offers: []}}
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
    -- Field paths TBD — no live 200 response yet (all xref rows are active=false).
    -- Returns empty result set; normalize_drain logs rows_inserted=0.
    WHEN 'TM' THEN
      RAISE NOTICE 'ticketsdata_normalize_listings: TM field paths not yet confirmed — returning 0 rows. Inspect net._http_response for raw body structure.';
      RETURN;

    ELSE
      RAISE EXCEPTION 'ticketsdata_normalize_listings: unknown platform %', p_platform;

  END CASE;
END $$;

REVOKE ALL ON FUNCTION public.ticketsdata_normalize_listings(text, jsonb) FROM anon, public;
COMMENT ON FUNCTION public.ticketsdata_normalize_listings(text, jsonb) IS
  'Parses raw TicketsData /fetch response into normalized offer rows. '
  'SH arm fixed 2026-05-27: priceWithFees→rawPrice (confirmed no priceWithFees in real SH responses, req 243861). '
  'GT/TP arms present for when xref rows are activated with real event URLs. '
  'TM arm stub — field paths TBD pending first live 200 response. '
  'VD/GT/TP body paths from D0 live tests (branch claude/resume-d0-chat-itUGb).';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. td_pending_sweep() — add GT/TP deactivation (platform-scoped, sg_event_id)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_pending_sweep()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_pending_sweep') THEN RETURN; END IF;

  -- Prune old resolved rows (keep 7 days of history)
  DELETE FROM public.td_pull_queue
  WHERE resolved_at IS NOT NULL
    AND created_at < v_now - interval '7 days';

  -- Reset stuck rows: fired but not resolved after 1 hour
  UPDATE public.td_pull_queue
  SET resolved_at = v_now,
      status_code = -1,
      error_msg   = 'timeout_sweep — pg_net request unresolved after 1h'
  WHERE fired_at IS NOT NULL
    AND resolved_at IS NULL
    AND fired_at < v_now - interval '1 hour';

  -- Deactivate past events — platform-scoped to avoid cross-namespace ID collisions

  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND platform = 'SH'
    AND event_id IN (
      SELECT aem.sh_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
        AND aem.sh_event_id IS NOT NULL
    );

  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND platform = 'VD'
    AND event_id IN (
      SELECT aem.vivid_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
        AND aem.vivid_event_id IS NOT NULL
    );

  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND platform = 'TM'
    AND event_id IN (
      SELECT aem.tm_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
        AND aem.tm_event_id IS NOT NULL
    );

  -- GT + TP: keyed by sg_event_id (no platform-specific ID column for these)
  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND platform IN ('GT', 'TP')
    AND event_id IN (
      SELECT sgc.sg_event_id
      FROM public.sg_events_canonical sgc
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
    );

END $$;

REVOKE ALL ON FUNCTION public.td_pending_sweep() FROM anon, public;
COMMENT ON FUNCTION public.td_pending_sweep() IS
  'Hourly cleanup: prune 7d+ resolved rows, reset stuck requests, deactivate past events. '
  'Platform-scoped deactivation: SH→sh_event_id, VD→vivid_event_id, TM→tm_event_id, GT+TP→sg_event_id.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Update cron_policy notes
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE public.cron_policy
SET notes = 'TD daily watchlist re-rank + URL upsert. 9 UTC = 5am ET. '
            'SH+VD active (direct_id). GT+TP+TM registered inactive (pending_discovery). '
            'SH re-activated 2026-05-27 (confirmed working, req 243861). '
            'GT/TP: /events discovery blocked (GT 500, TP initial_fetch_failed); operator can manually set URLs.',
    updated_at = now()
WHERE jobname = 'td_watchlist_refresh';

UPDATE public.cron_policy
SET notes = 'TD enqueue peak 4x/day: noon/4pm/8pm/11pm ET; 80 pairs/fire = 40 events × SH+VD. '
            'GT/TP inactive until URL discovery resolves. Budget: 40×2×4 = 320 credits/day.',
    updated_at = now()
WHERE jobname = 'td_enqueue_peak';
