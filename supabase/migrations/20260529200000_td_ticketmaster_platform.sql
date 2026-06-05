-- ============================================================
-- Ticketmaster (TM) as a TicketsData platform — mirrors TickPick (TP).
-- Authored by A1 (a1/td lane) 2026-05-29.
-- ============================================================
-- TM = PRIMARY (box-office) inventory via TD's `ticketmaster` scraper.
--
-- DISCOVERY: /events?platform=ticketmaster&performer_url=<TM artist page>.
--   TM lists many variants per game; we keep ONLY the primary listing:
--     url LIKE 'https://www.ticketmaster.com/%/event/%'  (excludes gofevo "Group Tickets")
--     title ILIKE '%vs.%' AND title NOT LIKE '%*%'        (excludes "* Premium Seating *",
--                                                          "Pinstripe Pass *", "* Group Tickets *")
--   Match to a focus event by venue (Yankee Stadium / MSG) + datetime (±18h), DISTINCT ON aq
--   so each game gets exactly ONE TM xref row (no 4× variant duplication).
--
-- FETCH: /fetch returns Ticketmaster ISMDS EventFacets —
--   body.facets[] : { section, count (seats avail), offers:[offerId] }
--   body._embedded.offer[] : { offerId, listPrice (face), totalPrice (w/fees+tax), name }
--   Normalizer emits one row per facet×offer: list_price=offer.listPrice,
--   price_with_fees=offer.totalPrice, quantity=facet.count.
--
-- ID MAPPING: TM host event id is hex (e.g. 1D006323F57B42E4); xref.event_id is bigint.
--   We map deterministically: ('x'||lpad(hexid,16,'0'))::bit(64)::bigint. The hex id also
--   tails the event_url, and discoveryId is preserved in xref.td_event_id.
--
-- Pull/enqueue/normalize machinery (td_enqueue_peak, td_pull_drain, td_normalize_drain) is
-- already platform-agnostic — TM needs only: normalizer branch + performers + discover/drain
-- + an enqueue cron + the apply_targets keep-clause. (td_api_platform already maps TM->ticketmaster;
-- xref CHECK already allows TM; metrics columns td_tm_* shipped in 20260529190000.)
-- ============================================================

-- ── 1) Normalizer: fill the TM branch (full CASE reproduced; SH/VD/GT/TP unchanged) ──
CREATE OR REPLACE FUNCTION public.ticketsdata_normalize_listings(p_platform text, p_content jsonb)
 RETURNS TABLE(td_listing_id text, section text, "row" text, quantity integer, list_price numeric, price_with_fees numeric, is_parking boolean, raw jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
BEGIN
  CASE p_platform
    WHEN 'SH' THEN
      RETURN QUERY SELECT (item->>'listingId')::text, public.td_normalize_section(item->>'section'),
        item->>'row', (item->>'availableTickets')::int, (item->>'rawPrice')::numeric, (item->>'rawPrice')::numeric,
        (lower(COALESCE(item->>'ticketClassName','')) LIKE '%parking%')::boolean, item
      FROM jsonb_array_elements(p_content->'body'->'items') AS item;
    WHEN 'VD' THEN
      RETURN QUERY SELECT (offer->>'listingId')::text, public.td_normalize_section(offer->>'section'),
        offer->>'row', (offer->>'availableTickets')::int, (offer->>'rawPrice')::numeric, (offer->>'rawPriceWithFees')::numeric,
        false::boolean, offer
      FROM jsonb_array_elements(p_content->'items'->'offers') AS offer;
    WHEN 'GT' THEN
      RETURN QUERY SELECT (item->>'listing_id')::text, public.td_normalize_section(item->>'section_name'),
        item->>'row', (item->>'quantity')::int, (item->'price'->>'prefee')::numeric, (item->'price'->>'total')::numeric,
        (lower(COALESCE(item->>'ticket_type','')) = 'parking')::boolean, item
      FROM jsonb_array_elements(p_content->'body') AS item;
    WHEN 'TP' THEN
      RETURN QUERY SELECT (offer->>'listing_id')::text, public.td_normalize_section(offer->>'section_name'),
        offer->>'row', (offer->>'quantity')::int, (offer->>'price')::numeric,
        (offer->>'price')::numeric + COALESCE((offer->'fees'->>'delivery')::numeric,0)
          + COALESCE((offer->'fees'->>'facility')::numeric,0) + COALESCE((offer->'fees'->>'service')::numeric,0),
        COALESCE((offer->>'is_parking')::boolean, false), offer
      FROM jsonb_array_elements(p_content->'items'->'offers') AS offer;
    WHEN 'TM' THEN
      RETURN QUERY
      SELECT
        (oid || ':' || COALESCE(facet->>'section','') || ':' || COALESCE(facet->'shapes'->>0,''))::text,
        public.td_normalize_section(facet->>'section'),
        NULL::text,
        NULLIF((facet->>'count')::int, 0),
        (m.off->>'listPrice')::numeric,
        (m.off->>'totalPrice')::numeric,
        (lower(COALESCE(facet->>'section','')) LIKE '%parking%'
          OR lower(COALESCE(m.off->>'name','')) LIKE '%parking%')::boolean,
        jsonb_build_object('facet', facet, 'offer', m.off)
      FROM jsonb_array_elements(COALESCE(p_content->'body'->'facets','[]'::jsonb)) AS facet
      CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(facet->'offers','[]'::jsonb)) AS oid
      LEFT JOIN LATERAL (
        SELECT off_el AS off
        FROM jsonb_array_elements(COALESCE(p_content->'body'->'_embedded'->'offer','[]'::jsonb)) AS off_el
        WHERE off_el->>'offerId' = oid
        LIMIT 1
      ) m ON true
      WHERE COALESCE((facet->>'available')::boolean, true) = true
        AND m.off->>'listPrice' IS NOT NULL;
    ELSE RAISE EXCEPTION 'ticketsdata_normalize_listings: unknown platform %', p_platform;
  END CASE;
END $function$;

-- ── 2) TM performers (mirror td_tp_performers) ──
CREATE TABLE IF NOT EXISTS public.td_tm_performers (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  performer_url               text NOT NULL UNIQUE,
  active                      boolean NOT NULL DEFAULT true,
  last_discovered_at          timestamptz,
  pending_discover_request_id bigint,
  updated_at                  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.td_tm_performers (performer_url) VALUES
  ('https://www.ticketmaster.com/new-york-yankees-tickets/artist/805992'),
  ('https://www.ticketmaster.com/new-york-knicks-tickets/artist/805988')
ON CONFLICT (performer_url) DO NOTHING;

-- ── 3) Discover: fire /events for each TM performer (mirror td_tp_discover) ──
CREATE OR REPLACE FUNCTION public.td_tm_discover()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE r RECORD; v_user text; v_pass text; v_req_id bigint; v_count int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_tm_discover') THEN RETURN 0; END IF;
  IF NOT public.td_budget_ok() THEN RAISE NOTICE 'td_tm_discover: budget exhausted'; RETURN 0; END IF;
  v_user := public.get_app_secret('TICKETSDATA_USERNAME'); v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
  IF v_user IS NULL OR v_pass IS NULL THEN RAISE EXCEPTION 'td_tm_discover: creds missing'; END IF;
  FOR r IN SELECT id, performer_url FROM public.td_tm_performers
    WHERE active = true AND (pending_discover_request_id IS NULL OR last_discovered_at IS NULL
      OR last_discovered_at < clock_timestamp() - interval '22 hours') ORDER BY id
  LOOP
    SELECT net.http_get(url := 'https://ticketsdata.com/events',
      params := jsonb_build_object('platform','ticketmaster','performer_url',r.performer_url,'username',v_user,'password',v_pass),
      headers := '{}'::jsonb, timeout_milliseconds := 40000) INTO v_req_id;
    UPDATE public.td_tm_performers SET pending_discover_request_id = v_req_id, updated_at = clock_timestamp() WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;

-- ── 4) Discover-drain: parse /events, keep primary listing only, match venue+datetime,
--        DISTINCT ON aq (one TM xref per game), hex->bigint event_id ──
CREATE OR REPLACE FUNCTION public.td_tm_discover_drain()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE r RECORD; v_count int := 0; v_n int;
BEGIN
  IF NOT public.cron_should_fire('td_tm_discover_drain') THEN RETURN 0; END IF;
  FOR r IN SELECT p.id AS performer_id, h.status_code, h.content AS raw_content
    FROM public.td_tm_performers p JOIN net._http_response h ON h.id = p.pending_discover_request_id
    WHERE p.active = true AND p.pending_discover_request_id IS NOT NULL ORDER BY p.id
  LOOP
    IF r.status_code = 200 THEN
      WITH items AS (
        SELECT item->>'id' AS tm_hex, item->>'url' AS event_url, item->>'discoveryId' AS discovery_id,
               (item->'dates'->>'startDate')::timestamptz AS dt_utc, item->'venue'->>'name' AS venue
        FROM jsonb_array_elements(COALESCE(r.raw_content::jsonb->'body'->'items','[]'::jsonb)) AS item
        WHERE item->>'id' ~ '^[0-9A-Fa-f]{1,16}$'
          AND item->>'url' LIKE 'https://www.ticketmaster.com/%/event/%'
          AND item->>'title' ILIKE '%vs.%' AND item->>'title' NOT LIKE '%*%'
          AND COALESCE((item->>'cancelled')::boolean, false) = false
          AND (item->'dates'->>'startDate') IS NOT NULL
      ),
      matched AS (
        SELECT DISTINCT ON (t.aq_short_event_id)
          t.aq_short_event_id, i.tm_hex, i.event_url, i.discovery_id
        FROM items i
        CROSS JOIN public.td_target_events() t
        JOIN public.aq_event_map aem ON aem.aq_short_event_id = t.aq_short_event_id
        WHERE abs(extract(epoch FROM (aem.event_date::timestamptz - i.dt_utc))) < 64800
          AND ((aem.event_name ILIKE '%yankees%' AND i.venue ILIKE '%yankee stadium%')
            OR (aem.event_name ILIKE '%knicks%'  AND i.venue ILIKE '%madison square garden%'))
        ORDER BY t.aq_short_event_id, abs(extract(epoch FROM (aem.event_date::timestamptz - i.dt_utc)))
      )
      INSERT INTO public.ticketsdata_event_xref
        (event_id, platform, aq_short_event_id, event_url, td_event_id, active, always_on, match_method, updated_at)
      SELECT ('x'||lpad(tm_hex,16,'0'))::bit(64)::bigint, 'TM', aq_short_event_id, event_url, discovery_id,
             true, true, 'tm_events_venue_date', clock_timestamp()
      FROM matched
      ON CONFLICT (event_id, platform) DO UPDATE
        SET event_url = EXCLUDED.event_url, td_event_id = EXCLUDED.td_event_id, active = true, always_on = true,
            aq_short_event_id = EXCLUDED.aq_short_event_id, match_method = 'tm_events_venue_date', updated_at = clock_timestamp();
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_count := v_count + v_n;
      PERFORM public.td_charge_credit(1, NULL, 'TM', '/events', 200, (r.raw_content::jsonb->>'quota_remaining')::int);
    END IF;
    UPDATE public.td_tm_performers SET pending_discover_request_id = NULL, last_discovered_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE id = r.performer_id;
  END LOOP;
  RETURN v_count;
END $function$;

-- ── 5) apply_targets: add TM to the keep-clause so it isn't deactivated (mirror TP) ──
CREATE OR REPLACE FUNCTION public.td_apply_targets()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_count int := 0; v_now timestamptz := now();
BEGIN
  WITH t AS (SELECT * FROM public.td_target_events() WHERE sh_event_id IS NOT NULL)
  INSERT INTO public.ticketsdata_event_xref (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
  SELECT t.sh_event_id, 'SH', t.aq_short_event_id, 'https://www.stubhub.com/x/event/' || t.sh_event_id::text || '/', true, true, 'direct_id', v_now
  FROM t ON CONFLICT (event_id, platform) DO UPDATE SET active=true, always_on=true, event_url=EXCLUDED.event_url, updated_at=v_now;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  WITH t AS (SELECT * FROM public.td_target_events() WHERE vivid_event_id IS NOT NULL)
  INSERT INTO public.ticketsdata_event_xref (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
  SELECT t.vivid_event_id, 'VD', t.aq_short_event_id, 'https://www.vividseats.com/production/' || t.vivid_event_id::text, true, true, 'direct_id', v_now
  FROM t ON CONFLICT (event_id, platform) DO UPDATE SET active=true, always_on=true, event_url=EXCLUDED.event_url, updated_at=v_now;
  UPDATE public.ticketsdata_event_xref x SET active=false, updated_at=v_now
  WHERE x.active=true AND NOT EXISTS (SELECT 1 FROM public.td_target_events() t
    WHERE (x.platform='SH' AND x.event_id=t.sh_event_id) OR (x.platform='VD' AND x.event_id=t.vivid_event_id)
       OR (x.platform='GT' AND x.event_id=t.sg_event_id) OR (x.platform='TP' AND x.aq_short_event_id=t.aq_short_event_id)
       OR (x.platform='TM' AND x.aq_short_event_id=t.aq_short_event_id));
  UPDATE public.ticketsdata_event_xref x SET always_on=true, updated_at=v_now
  WHERE x.platform='GT' AND x.active=true AND EXISTS (SELECT 1 FROM public.td_target_events() t WHERE t.sg_event_id=x.event_id);
  UPDATE public.ticketsdata_event_xref x SET owned_tickets=COALESCE(em_data.owned_tickets_count,0), median_retail_price=em_data.retail_median, updated_at=v_now
  FROM public.aq_event_map aem JOIN public.sg_events_canonical sgc ON sgc.sg_event_id=aem.sg_event_id
  LEFT JOIN LATERAL (SELECT em.owned_tickets_count, em.retail_median FROM public.event_metrics em
    WHERE em.event_id=sgc.tevo_event_id ORDER BY em.captured_at DESC LIMIT 1) em_data ON true
  WHERE aem.aq_short_event_id=x.aq_short_event_id AND x.active=true AND sgc.tevo_event_id IS NOT NULL;
  RETURN v_count;
END $function$;

-- ── 6) Crons (mirror TP cadence, staggered minutes) ──
SELECT cron.schedule('td_tm_discover', '45 9 * * *',
  $job$ DO $b$ BEGIN IF NOT public.cron_should_fire('td_tm_discover') THEN RETURN; END IF; PERFORM public.td_tm_discover(); END $b$; $job$);
SELECT cron.schedule('td_tm_discover_drain', '50 9 * * *',
  $job$ DO $b$ BEGIN IF NOT public.cron_should_fire('td_tm_discover_drain') THEN RETURN; END IF; PERFORM public.td_tm_discover_drain(); END $b$; $job$);
SELECT cron.schedule('td_enqueue_peak_tm', '30 16,22,4 * * *',
  $job$ DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('TM',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 16 THEN '12pm_ET' WHEN 22 THEN '6pm_ET'
          WHEN  4 THEN '12am_ET' ELSE 'manual' END);
    END $b$; $job$);

-- Post-apply test sequence (manual):
--   SELECT public.td_tm_discover();            -- fires /events (Yankees+Knicks)
--   -- wait ~30s --
--   SELECT public.td_tm_discover_drain();      -- inserts TM xref
--   SELECT count(*) FROM ticketsdata_event_xref WHERE platform='TM' AND active;
--   SELECT public.td_enqueue_peak('TM','manual');  -- queue /fetch
--   SELECT public.td_pull_drain(10);           -- fire /fetch
--   -- wait ~30s --
--   SELECT public.td_normalize_drain(50);      -- normalize into ticketsdata_listings_snapshots
--   SELECT count(*), round(percentile_cont(0.5) within group (order by list_price)) med
--     FROM ticketsdata_listings_snapshots WHERE platform='TM' AND captured_at > now()-interval '1 hour';
