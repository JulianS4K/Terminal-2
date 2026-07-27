-- 20260606194100_cron_redesign_4_seller_full_pull_aq_map.sql
--
-- ## Already applied to prod — applied via MCP 2026-06-06 (operator-authorized)
--
-- Trading-hours cadence redesign #4 (CRON_HIERARCHY §4c). Pull the FULL SG SellerDirect
-- book (our own ~290k listings, cursor-paginated; previously page-1-only = 0.17%) + AQ-map
-- each listing to its canonical TEvo event.
--   (a) rolling keyset cursor in sg_seller_listings_queue — advances 1 page/tick (reads the
--       last processed page's meta.next_page), loops at end, self-heals stale pendings; does
--       NOT touch the working orders+listings sg_seller_process().
--   (b) sg_seller_sync_and_map() — register seller events into sg_events_canonical
--       (has_seller_listings) + backfill seatgeek_seller_listings.tevo_event_id from canonical
--       (SG->TEvo resolved by the existing auto_match_sg_canonical_v3_hourly cron).
--   (c) reschedule: queue */2 (guarded by prev-resolved), process every 2 min, sync+map */15.
-- The /orders side (seatgeek_orders) is OBSOLETE (operator directive 2026-06-06) — not touched.

CREATE OR REPLACE FUNCTION public.sg_seller_listings_queue(p_pages integer DEFAULT 1)
RETURNS integer LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $fn$
DECLARE
  v_token  text := get_app_secret('SEATGEEK_API_TOKEN');
  v_cursor text;
  v_url    text;
  v_req_id bigint;
BEGIN
  PERFORM p_pages;  -- ABI compat; rolling cursor advances one page per call
  UPDATE public.sg_seller_pending
     SET resolved_at = now(), rows_persisted = -1
   WHERE scope='listings' AND resolved_at IS NULL AND fired_at < now() - interval '20 minutes';
  IF EXISTS (SELECT 1 FROM public.sg_seller_pending WHERE scope='listings' AND resolved_at IS NULL) THEN
    RETURN 0;
  END IF;
  SELECT NULLIF(h.content::jsonb->'meta'->>'next_page','')
    INTO v_cursor
  FROM public.sg_seller_pending p
  JOIN net._http_response h ON h.id = p.request_id
  WHERE p.scope='listings' AND p.resolved_at IS NOT NULL AND h.status_code = 200
  ORDER BY p.id DESC LIMIT 1;

  v_url := 'https://sellerdirect-api.seatgeek.com/listings?per_page=500&token=' || v_token;
  IF v_cursor IS NOT NULL THEN
    v_url := v_url || '&page=' || v_cursor;
  END IF;
  SELECT net.http_get(url := v_url, timeout_milliseconds := 30000) INTO v_req_id;
  INSERT INTO public.sg_seller_pending(request_id, scope, page, per_page) VALUES (v_req_id, 'listings', 1, 500);
  RETURN 1;
END $fn$;

CREATE OR REPLACE FUNCTION public.sg_seller_sync_and_map()
RETURNS TABLE(events_synced integer, listings_mapped integer)
LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_synced int := 0; v_mapped int := 0;
BEGIN
  SELECT COALESCE(rows_inserted,0) + COALESCE(rows_updated,0)
    INTO v_synced FROM public.sync_sg_seller_listings_to_canonical();
  WITH upd AS (
    UPDATE public.seatgeek_seller_listings ssl
       SET tevo_event_id = c.tevo_event_id
      FROM public.sg_events_canonical c
     WHERE c.sg_event_id = ssl.sg_event_id
       AND c.tevo_event_id IS NOT NULL
       AND ssl.tevo_event_id IS DISTINCT FROM c.tevo_event_id
    RETURNING 1)
  SELECT count(*) INTO v_mapped FROM upd;
  RETURN QUERY SELECT v_synced, v_mapped;
END $fn$;
REVOKE ALL ON FUNCTION public.sg_seller_sync_and_map() FROM anon, public;

SELECT cron.schedule('sg_seller_listings_queue_30min','*/2 * * * *', $c$SELECT public.sg_seller_listings_queue(1);$c$);
SELECT cron.schedule('sg_seller_process_30min','1-59/2 * * * *', $c$SELECT public.sg_seller_process();$c$);
SELECT cron.schedule('sg_seller_sync_map_15min','*/15 * * * *', $c$SELECT public.sg_seller_sync_and_map();$c$);
