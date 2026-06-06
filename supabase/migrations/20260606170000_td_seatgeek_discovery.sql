-- Migration 20260606170000 · lane:D0 · writes: td_sg_performers (new table) +
--   td_sg_discover() + td_sg_discover_drain() · reads: events/aq_event_map ·
--   writes on run: sg_events_canonical · spends: TicketsData credits (budget-gated)
--
-- ## Already applied to prod · Applied via MCP 2026-06-06 (operator-authorized)
--
-- TD -> SeatGeek event discovery. Closes the SG catalog-coverage gap for events we
-- don't own: our SG broker token has NO search endpoint, but TicketsData's
-- /events?platform=seatgeek DOES search SeatGeek by performer. We use it sparingly
-- (TD credits are limited; every call is gated by td_budget_ok()) to discover
-- sg_event_ids for high-value unmapped TEvo performers, insert them into
-- sg_events_canonical, and let auto_match_sg_canonical_v3() link them to TEvo.
--
-- USAGE IS DELIBERATELY MANUAL - no cron is scheduled. Run, when td_budget_ok():
--   SELECT public.td_sg_discover(2);   -- fire N (small) performer searches
--   -- wait ~30s for pg_net responses, then:
--   SELECT public.td_sg_discover_drain();  -- parse -> canonical -> matcher
--
-- VERIFICATION-PENDING: the drain assumes the same TD envelope as
-- td_tp_discover_drain (body.items[] with event_id / buy_url / event_date_utc /
-- display_name). The SeatGeek item field names are inferred from that pattern; the
-- FIRST live drain (a 2-performer probe) confirms them - adjust field names here if
-- the SG payload differs. sg_event_id := item.event_id, falling back to the numeric
-- id in the seatgeek.com buy_url. ON CONFLICT DO NOTHING keeps re-runs safe.
-- (TD daily budget was exhausted on the build date, so the probe is deferred to the
-- next budget window.)

CREATE TABLE IF NOT EXISTS public.td_sg_performers (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tevo_performer_id           bigint,
  performer_name              text NOT NULL,
  performer_url               text NOT NULL,
  active                      boolean NOT NULL DEFAULT true,
  pending_discover_request_id bigint,
  last_discovered_at          timestamptz,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tevo_performer_id)
);

COMMENT ON TABLE public.td_sg_performers IS
  'Allowlist of high-value unmapped TEvo performers to discover on SeatGeek via the '
  'TicketsData /events?platform=seatgeek search. Drives td_sg_discover(). Budget-gated.';

INSERT INTO public.td_sg_performers (tevo_performer_id, performer_name, performer_url)
SELECT v.id, v.nm,
       'https://seatgeek.com/' || trim(both '-' from regexp_replace(lower(v.nm),'[^a-z0-9]+','-','g')) || '-tickets'
FROM (VALUES
  (52816,'Harry Styles'),(29186,'Ed Sheeran'),(27474,'Ariana Grande'),(1847,'Bruno Mars'),
  (10102,'Shakira'),(2306,'Chris Brown'),(6809,'Lionel Richie'),(62233,'Karol G'),
  (51824,'Daniel Caesar'),(60259,'Noah Kahan'),(87567,'Megan Moroney'),(12692,'Usher'),
  (68034,'Joji'),(29994,'J Cole'),(12980,'Weezer'),(22207,'Tame Impala'),
  (84524,'Benson Boone'),(9776,'Rush'),(109873,'Forrest Frank')
) AS v(id,nm)
ON CONFLICT (tevo_performer_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.td_sg_discover(p_limit integer DEFAULT 5)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp
AS $fn$
DECLARE r RECORD; v_user text; v_pass text; v_req bigint; v_n int := 0;
BEGIN
  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_sg_discover: TD budget exhausted - skipping'; RETURN 0;
  END IF;
  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
  IF v_user IS NULL OR v_pass IS NULL THEN RAISE EXCEPTION 'td_sg_discover: TD creds missing'; END IF;
  FOR r IN
    SELECT id, performer_url FROM public.td_sg_performers
    WHERE active AND pending_discover_request_id IS NULL
      AND (last_discovered_at IS NULL OR last_discovered_at < now() - interval '7 days')
    ORDER BY id LIMIT GREATEST(p_limit, 0)
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/events',
      params := jsonb_build_object('platform','seatgeek','performer_url',r.performer_url,
                                   'username',v_user,'password',v_pass),
      headers := '{}'::jsonb, timeout_milliseconds := 35000
    ) INTO v_req;
    UPDATE public.td_sg_performers SET pending_discover_request_id = v_req, updated_at = now() WHERE id = r.id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $fn$;

CREATE OR REPLACE FUNCTION public.td_sg_discover_drain()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp
AS $fn$
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
        SELECT item FROM jsonb_array_elements(r.raw::jsonb->'body'->'items') AS item
      LOOP
        v_sg := NULLIF(regexp_replace(coalesce(ev.item->>'event_id',''),'\D','','g'),'')::bigint;
        IF v_sg IS NULL THEN
          v_sg := (substring(coalesce(ev.item->>'buy_url',''), 'seatgeek\.com/.*?([0-9]{6,})'))::bigint;
        END IF;
        IF v_sg IS NOT NULL AND (ev.item->>'event_date_utc') IS NOT NULL THEN
          INSERT INTO public.sg_events_canonical
            (sg_event_id, sg_event_name, sg_event_date, sg_venue_name, sg_category,
             has_seller_listings, has_orders, has_v2_listings_pulled,
             match_method, match_status, raw_event_jsonb, created_at, updated_at)
          VALUES (
            v_sg,
            coalesce(ev.item->>'name', ev.item->>'title', ev.item->>'display_name', r.performer_name),
            NULLIF(left(ev.item->>'event_date_utc',10),'')::date,
            coalesce(ev.item->>'venue', ev.item->>'display_name'),
            'concert', false, false, false,
            'td_seatgeek_search', 'pending', ev.item, now(), now())
          ON CONFLICT (sg_event_id) DO NOTHING;
          v_ins := v_ins + 1;
        END IF;
      END LOOP;
      PERFORM public.td_charge_credit(1, NULL, 'SG', '/events', 200,
              (r.raw::jsonb->>'quota_remaining')::int);
    END IF;
    UPDATE public.td_sg_performers
      SET pending_discover_request_id = NULL, last_discovered_at = now(), updated_at = now()
      WHERE id = r.pid;
  END LOOP;
  IF v_ins > 0 THEN PERFORM public.auto_match_sg_canonical_v3(); END IF;
  RETURN v_ins;
END $fn$;
