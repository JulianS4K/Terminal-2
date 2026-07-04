-- Migration 20260703133000 · lane:A1 (data plane — SeatGeek discovery data quality)
--   writes (DDL): td_sg_discover_drain() [CREATE OR REPLACE — add sg_url]
--   writes on run: sg_events_canonical (one-time backfill of sg_url on existing
--                  match_method='td_seatgeek_search' rows from raw_event_jsonb->>'url')
--   reads: sg_events_canonical.raw_event_jsonb
--   spends: nothing
--   pre: 20260703132000 (drain sg_datetime_utc fix — this builds on that body)
--   auth: operator directive 2026-07-03 (julian@s4kent.com — "map sg events, then
--         run td matcher on this events")
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- Second field the discovery drain dropped: sg_url. The TicketsData /match filler
-- sg_match_map_tick() selects candidates via
--   JOIN sg_events_canonical sgc ON sgc.sg_event_id = a.sg_event_id AND sgc.sg_url IS NOT NULL
-- and passes sgc.sg_url as the /match event_url. Discovered rows had sg_url NULL,
-- so even once anchored on the AQ hub (mig 20260703132000) they were never picked
-- for the sh/vivid /match — sg_match_map_tick returned fired=0 with no candidate.
--
-- The raw /events payload carries the canonical SeatGeek event URL in item.url
-- (e.g. https://seatgeek.com/us-open-...-tickets/tennis/2026-08-25-11-am/18238368),
-- which /match resolves. Store it (+ backfill existing). With this, the ~15 (and
-- growing) anchored US Open sessions become live /match candidates on the existing
-- sg-match-map-tick cron (*/10, one serialized /match per tick, owned-first).
-- ─────────────────────────────────────────────────────────────────────────────

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
        SELECT item FROM jsonb_array_elements(r.raw::jsonb->'body'->'items'->'events') AS item
      LOOP
        v_sg := NULLIF(regexp_replace(coalesce(ev.item->>'id',''),'\D','','g'),'')::bigint;
        IF v_sg IS NULL THEN
          v_sg := (substring(coalesce(ev.item->>'url', ev.item->>'buy_url',''), 'seatgeek\.com/.*?([0-9]{6,})'))::bigint;
        END IF;
        IF v_sg IS NOT NULL
           AND coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc') IS NOT NULL THEN
          INSERT INTO public.sg_events_canonical
            (sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_url, sg_venue_name, sg_category,
             has_seller_listings, has_orders, has_v2_listings_pulled,
             match_method, match_status, raw_event_jsonb, created_at, updated_at)
          VALUES (
            v_sg,
            coalesce(ev.item->>'title', ev.item->>'short_title', ev.item->>'name', r.performer_name),
            NULLIF(left(coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc'),10),'')::date,
            (NULLIF(coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc'),'')::timestamp AT TIME ZONE 'UTC'),
            NULLIF(coalesce(ev.item->>'url', ev.item->>'buy_url'),''),
            coalesce(ev.item->'venue'->>'name', ev.item->>'venue'),
            coalesce(ev.item->>'type', 'concert'),
            false, false, false,
            'td_seatgeek_search', 'pending', ev.item, now(), now())
          ON CONFLICT (sg_event_id) DO NOTHING;
          v_ins := v_ins + 1;
        END IF;
      END LOOP;
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

-- One-time backfill: fill sg_url on already-discovered rows from the raw payload.
UPDATE public.sg_events_canonical
SET sg_url = NULLIF(coalesce(raw_event_jsonb->>'url', raw_event_jsonb->>'buy_url'),''),
    updated_at = now()
WHERE match_method = 'td_seatgeek_search'
  AND sg_url IS NULL
  AND coalesce(raw_event_jsonb->>'url', raw_event_jsonb->>'buy_url') IS NOT NULL;

-- ROLLBACK: restore the mig 20260703132000 drain body (without sg_url) + the
-- backfilled sg_url values are harmless to leave.
