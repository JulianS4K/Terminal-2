-- ============================================================
-- TM platform fixes (discovered during post-apply testing of 20260529200000).
-- Authored by A1 (a1/td lane) 2026-05-29.
-- ============================================================
-- FIX 1 — td_pull_queue platform CHECK was never extended to TM (it has SH/VD/GT/TP
--   but not TM), so td_enqueue_peak('TM',...) raised 23514. The xref constraint already
--   allows TM; the queue's own constraint did not. (Same class as the Phase-20 TickPick
--   xref-constraint gap, different table.)
-- FIX 2 — td_tm_discover_drain required title ILIKE '%vs.%', which captured Yankees home
--   games ("New York Yankees vs. X") but MISSED Knicks Finals ("NBA Finals: TBD at New
--   York Knicks RD4 HM GM1" — uses "at", opponent TBD). Relax to: exclude only the noise
--   variants ('*' = Group/Premium/Pinstripe, 'parking'), rely on venue+team+date match,
--   and prefer canonical game titles ("vs."/" at ") in the DISTINCT ON tiebreak so Yankees
--   still resolves to the standard listing (not a same-time variant).
-- ============================================================

ALTER TABLE public.td_pull_queue DROP CONSTRAINT IF EXISTS td_pull_queue_platform_check;
ALTER TABLE public.td_pull_queue ADD CONSTRAINT td_pull_queue_platform_check
  CHECK (platform = ANY (ARRAY['SH','VD','GT','TM','TP']::text[]));

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
               item->>'title' AS title,
               (item->'dates'->>'startDate')::timestamptz AS dt_utc, item->'venue'->>'name' AS venue
        FROM jsonb_array_elements(COALESCE(r.raw_content::jsonb->'body'->'items','[]'::jsonb)) AS item
        WHERE item->>'id' ~ '^[0-9A-Fa-f]{1,16}$'
          AND item->>'url' LIKE 'https://www.ticketmaster.com/%/event/%'
          AND item->>'title' NOT LIKE '%*%'
          AND lower(item->>'title') NOT LIKE '%parking%'
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
        ORDER BY t.aq_short_event_id,
                 (CASE WHEN i.title ILIKE '%vs.%' OR i.title ILIKE '% at %' THEN 0 ELSE 1 END),
                 abs(extract(epoch FROM (aem.event_date::timestamptz - i.dt_utc)))
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
