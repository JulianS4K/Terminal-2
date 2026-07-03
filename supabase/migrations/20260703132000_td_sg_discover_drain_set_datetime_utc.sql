-- Migration 20260703132000 · lane:A1 (data plane — SeatGeek discovery data quality)
--   writes (DDL): td_sg_discover_drain() [CREATE OR REPLACE — add sg_datetime_utc]
--   writes on run: sg_events_canonical (one-time backfill of sg_datetime_utc on
--                  existing match_method='td_seatgeek_search' rows)
--   reads: sg_events_canonical.raw_event_jsonb
--   spends: nothing
--   pre: 20260621000500 (last td_sg_discover_drain shape fix)
--   auth: operator directive 2026-07-03 (julian@s4kent.com — "map sg events, then
--         run td matcher on this events")
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- td_sg_discover_drain() parsed each TicketsData /events item's `datetime_utc`
-- (a full UTC timestamp, e.g. "2026-08-25T15:00:00") only far enough to derive
-- sg_event_date (left(...,10)) — it never stored sg_datetime_utc, leaving it NULL
-- on every discovered row. That NULL silently breaks the standard mapping chain:
--   • backfill_aq_maps() fills aq_event_map.sg_event_id via a
--     `aem.event_date BETWEEN sg_datetime_utc ± 4h` window join — NULL → no match,
--     so the discovered SG events never anchored onto the AQ hub, and
--   • sg_match_map_tick() (the TD /match sh/vivid filler) anchors on
--     aq_event_map.sg_event_id — so with the hub unpopulated it had nothing to run.
--   • sg_tevo_search_candidates() (cold bridge) filters sg_datetime_utc > now().
--
-- Concretely this blocked the ~85 US Open Tennis sessions just discovered on
-- SeatGeek (66 canonical rows, 43 already matched to TEvo by auto_match, which
-- uses date+name and so was unaffected) from reaching the sh/vivid TD-match step.
--
-- FIX: capture sg_datetime_utc in the drain (naive UTC → timestamptz via
--      AT TIME ZONE 'UTC'), and one-time backfill the rows already discovered.
--      Benefits ALL TD-seatgeek discoveries, not just US Open.
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
            (sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_venue_name, sg_category,
             has_seller_listings, has_orders, has_v2_listings_pulled,
             match_method, match_status, raw_event_jsonb, created_at, updated_at)
          VALUES (
            v_sg,
            coalesce(ev.item->>'title', ev.item->>'short_title', ev.item->>'name', r.performer_name),
            NULLIF(left(coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc'),10),'')::date,
            -- NEW: full UTC timestamp (naive UTC in payload → interpret as UTC)
            (NULLIF(coalesce(ev.item->>'datetime_utc', ev.item->>'event_date_utc'),'')::timestamp AT TIME ZONE 'UTC'),
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

-- One-time backfill: fill sg_datetime_utc on already-discovered rows from the raw
-- payload. Scoped to td_seatgeek_search rows still missing it; naive UTC → tstz.
UPDATE public.sg_events_canonical
SET sg_datetime_utc = (NULLIF(coalesce(raw_event_jsonb->>'datetime_utc',
                                       raw_event_jsonb->>'event_date_utc'),'')::timestamp AT TIME ZONE 'UTC'),
    updated_at = now()
WHERE match_method = 'td_seatgeek_search'
  AND sg_datetime_utc IS NULL
  AND coalesce(raw_event_jsonb->>'datetime_utc', raw_event_jsonb->>'event_date_utc') IS NOT NULL;

-- ROLLBACK: restore the prior td_sg_discover_drain body (mig 20260621000500) minus
-- the sg_datetime_utc column; the backfilled datetimes are harmless to leave.
