-- Migration 20260708161000 · lane:A1 (data plane — ingest/discovery) ·
--   writes (DDL): td_events_discover_drain() (recreate — Eventbrite field dialect) ·
--   reads: net._http_response, td_discover_targets ·
--   writes on run: td_discovered_events ·
--   spends: charges 1 TicketsData credit per drained 200 (already spent at fetch) ·
--   pre: 20260609130000 (td_events_discover_drain v1), 20260708160000 (eventbrite target)
--
-- ## APPLIED via MCP 2026-07-08 (operator-directed). Idempotent CREATE OR REPLACE;
--    re-apply is a no-op. This file is the codification.
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- The platform-generic drain (mig 20260609130000) parses the SeatGeek /events
-- dialect (name|title|display_name, buy_url|url, event_date_utc, flat venue).
-- The Eventbrite /events envelope (verified live 2026-07-08 against organizer
-- 105655500371, 72 items) uses DIFFERENT field names:
--     foreign_id · event_name · event_url · start_date/end_date ·
--     venue{} (nested object: name, city, region) · min/max_ticket_price ·
--     is_sold_out · has_available_tickets · image_url
-- The changes below are PURELY ADDITIVE — the SG field names stay first in every
-- COALESCE, so SG discovery is unaffected; the Eventbrite aliases are appended
-- as fallbacks, and nested venue{} is unwrapped. Full raw item is still stored
-- in td_discovered_events.raw, so downstream (the terminal Eventbrite tab) reads
-- price/availability/image straight from raw. Eventbrite also gets an explicit
-- 'EB' credit code (was falling through the generic ELSE to 'EV').
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.td_events_discover_drain()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; ev RECORD; v_id text; v_ins int := 0;
BEGIN
  FOR r IN
    SELECT t.id AS tid, t.platform, t.label, h.status_code, h.content AS raw
    FROM public.td_discover_targets t
    JOIN net._http_response h ON h.id = t.pending_request_id
    WHERE t.pending_request_id IS NOT NULL
  LOOP
    IF r.status_code = 200 THEN
      FOR ev IN SELECT item FROM jsonb_array_elements(
          COALESCE(r.raw::jsonb->'body'->'items', r.raw::jsonb->'items', '[]'::jsonb)) AS item
      LOOP
        -- id: SG (event_id/id) → Eventbrite (foreign_id) → digits in any URL → md5
        v_id := COALESCE(NULLIF(ev.item->>'event_id',''), NULLIF(ev.item->>'id',''),
          NULLIF(ev.item->>'foreign_id',''),
          NULLIF(substring(COALESCE(ev.item->>'buy_url', ev.item->>'url', ev.item->>'event_url',''), '([0-9]{5,})'),''),
          md5(ev.item::text));
        INSERT INTO public.td_discovered_events
          (platform, td_event_id, event_url, event_name, event_date, venue_name, city, performer_label, target_id, raw)
        VALUES (r.platform, v_id,
          COALESCE(ev.item->>'buy_url', ev.item->>'url', ev.item->>'link', ev.item->>'event_url'),
          COALESCE(ev.item->>'name', ev.item->>'title', ev.item->>'display_name', ev.item->>'event_name', r.label),
          NULLIF(left(COALESCE(ev.item->>'event_date_utc', ev.item->>'event_date',
                               ev.item->>'datetime_utc', ev.item->>'start_date',''), 10), '')::date,
          -- venue: unwrap nested venue{} (Eventbrite) else flat text (SG)
          COALESCE(CASE WHEN jsonb_typeof(ev.item->'venue')='object' THEN ev.item->'venue'->>'name'
                        ELSE ev.item->>'venue' END,
                   ev.item->>'venue_name'),
          COALESCE(ev.item->'venue'->>'city', ev.item->>'city', ev.item->>'venue_city'),
          r.label, r.tid, ev.item)
        ON CONFLICT (platform, td_event_id) DO UPDATE
          SET event_url = EXCLUDED.event_url, event_name = EXCLUDED.event_name,
              event_date = EXCLUDED.event_date, venue_name = EXCLUDED.venue_name,
              city = EXCLUDED.city, raw = EXCLUDED.raw;
        v_ins := v_ins + 1;
      END LOOP;
      PERFORM public.td_charge_credit(1, NULL,
        CASE r.platform WHEN 'seatgeek' THEN 'SG' WHEN 'stubhub' THEN 'SH' WHEN 'vividseats' THEN 'VD'
                        WHEN 'gametime' THEN 'GT' WHEN 'tickpick' THEN 'TP' WHEN 'ticketmaster' THEN 'TM'
                        WHEN 'eventbrite' THEN 'EB'
                        ELSE upper(left(r.platform,2)) END,
        '/events', 200, (r.raw::jsonb->>'quota_remaining')::int);
    END IF;
    UPDATE public.td_discover_targets SET pending_request_id = NULL, last_discovered_at = now(), updated_at = now()
    WHERE id = r.tid;
  END LOOP;
  IF v_ins > 0 THEN PERFORM public.td_match_discovered_to_local(); END IF;
  RETURN v_ins;
END $function$;
REVOKE ALL ON FUNCTION public.td_events_discover_drain() FROM anon, public;
