-- ============================================================================
-- Migration 20260621000500 — fix td_sg_discover_drain() response shape + fields
--
-- Lane:     A1 (data plane — owns td_* SeatGeek discovery ingest)
-- Touches:  td_sg_discover_drain() (W, CREATE OR REPLACE)
-- Pre-reqs: existing td_sg_discover_drain (the buggy definition)
--
-- WHY: the drain has NEVER successfully processed a TicketsData /events response
--   — every td_sg_performers row still has last_discovered_at = NULL. Two bugs:
--
--   1. WRONG PATH. It iterated `raw->'body'->'items'` with jsonb_array_elements,
--      but `items` is an OBJECT; the event array lives at
--      `raw->'body'->'items'->'events'`. Result: every call raised
--      "cannot extract elements from an object" and rolled back.
--
--   2. WRONG FIELD NAMES. It read event_id / event_date_utc / buy_url /
--      name|title|display_name / venue|display_name. The actual SeatGeek event
--      objects use: id, datetime_utc, url, title|short_title, venue.name.
--
--   Verified against a live UFC pull (net request 1010024, performer UFC=5895):
--   3 events returned, e.g. id 18158636 "UFC 329: McGregor vs Holloway II" @
--   T-Mobile Arena, datetime_utc 2026-07-11T21:00:00. The 3 rows were landed
--   manually so UFC 329 could link immediately; this CREATE OR REPLACE makes the
--   scheduled/manual path work for every future performer.
--
--   Also corrects the quota_remaining path for credit accounting
--   (body->items->>'quota_remaining').
--
-- NOTE: still no cron fires td_sg_discover / td_sg_discover_drain — that wiring
--   is a separate decision (it spends TD credits). This migration only makes the
--   drain CORRECT when invoked.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.td_sg_discover_drain()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; ev RECORD; v_sg bigint; v_ins int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pid, p.performer_name, h.status_code, h.content AS raw
    FROM public.td_sg_performers p
    JOIN net._http_response h ON h.id = p.pending_discover_request_id
    WHERE p.pending_discover_request_id IS NOT NULL
  LOOP
    IF r.status_code = 200 THEN
      FOR ev IN
        -- FIX: events array is at body->items->events (items is an object)
        SELECT item FROM jsonb_array_elements(r.raw::jsonb->'body'->'items'->'events') AS item
      LOOP
        -- FIX: SeatGeek event id is `id`; fall back to a numeric id in `url`/`buy_url`
        v_sg := NULLIF(regexp_replace(coalesce(ev.item->>'id',''),'\D','','g'),'')::bigint;
        IF v_sg IS NULL THEN
          v_sg := (substring(coalesce(ev.item->>'url', ev.item->>'buy_url',''), 'seatgeek\.com/.*?([0-9]{6,})'))::bigint;
        END IF;
        -- FIX: date field is datetime_utc (fall back to legacy event_date_utc)
        IF v_sg IS NOT NULL
           AND coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc') IS NOT NULL THEN
          INSERT INTO public.sg_events_canonical
            (sg_event_id, sg_event_name, sg_event_date, sg_venue_name, sg_category,
             has_seller_listings, has_orders, has_v2_listings_pulled,
             match_method, match_status, raw_event_jsonb, created_at, updated_at)
          VALUES (
            v_sg,
            -- FIX: name fields are title / short_title
            coalesce(ev.item->>'title', ev.item->>'short_title', ev.item->>'name', r.performer_name),
            NULLIF(left(coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc'),10),'')::date,
            -- FIX: venue is a nested object
            coalesce(ev.item->'venue'->>'name', ev.item->>'venue'),
            coalesce(ev.item->>'type', 'concert'),
            false, false, false,
            'td_seatgeek_search', 'pending', ev.item, now(), now())
          ON CONFLICT (sg_event_id) DO NOTHING;
          v_ins := v_ins + 1;
        END IF;
      END LOOP;
      -- FIX: quota_remaining lives under body->items
      PERFORM public.td_charge_credit(1, NULL, 'SG', '/events', 200,
              (r.raw::jsonb->'body'->'items'->>'quota_remaining')::int);
    END IF;
    UPDATE public.td_sg_performers
      SET pending_discover_request_id = NULL, last_discovered_at = now(), updated_at = now()
      WHERE id = r.pid;
  END LOOP;
  IF v_ins > 0 THEN PERFORM public.auto_match_sg_canonical_v3(); END IF;
  RETURN v_ins;
END $function$;
