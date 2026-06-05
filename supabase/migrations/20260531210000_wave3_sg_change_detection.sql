-- ============================================================
-- Wave 3 (SG half) — change-detection on the SG listings drain.
-- A1 2026-05-31. sg_broker_listings_process now skips writing a seatgeek_listings_snapshots
-- row when an identical-state snapshot (same content_hash = event:id:price:qty) already
-- exists for that sglid within the last 70 min — i.e. write only on CHANGE, plus a ~hourly
-- heartbeat (a still-listed group whose last snapshot is >70 min old writes once, so
-- "unchanged" never looks like "delisted"). The EVENT/SECTION aggregates are unaffected —
-- this only filters the raw INSERT (the aggregates run in the SG metrics-refresh crons over
-- whatever is current). Cuts redundant SG snapshot writes (~halves them at steady state).
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_broker_listings_process(p_limit integer DEFAULT 50)
RETURNS TABLE(processed integer, listings_persisted integer)
LANGUAGE plpgsql SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id, h.status_code, h.content::jsonb AS body, a.aq_short_event_id, x.tevo_event_id
    FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = p.sg_event_id
    LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = p.sg_event_id
    WHERE p.scope = 'listings' AND p.resolved_at IS NULL ORDER BY p.fired_at LIMIT p_limit
  LOOP
    v_processed := v_processed + 1; v_inserted := NULL;
    IF r.status_code = 200 AND jsonb_typeof(r.body->'listings') = 'array' THEN
      WITH src AS (SELECT l FROM jsonb_array_elements(r.body->'listings') AS l),
      ins AS (
        INSERT INTO public.seatgeek_listings_snapshots (
          tevo_event_id, sg_event_id, captured_at, sglid, display_id, retail_price_all_in, broadcast_price,
          deal_quality_score, quantity, splits, section, row, is_broker_owned, is_b2b, is_instant_download, is_sro,
          has_limited_view, is_wheelchair_acc, ada_details, delivery_method, in_hand_date, market_source, stock_type,
          seller_notes, endpoint, content_hash, raw, aq_short_event_id)
        SELECT r.tevo_event_id, r.sg_event_id, now(), NULLIF(l->>'sglid','')::bigint, l->>'id',
          NULLIF(l->>'pf','')::numeric, NULLIF(l->>'bp','')::numeric, NULLIF(l->>'ds','')::numeric, NULLIF(l->>'q','')::int,
          l->'sp', l->>'s', l->>'r', NULLIF(l->>'bo','')::boolean, NULLIF(l->>'is_b2b','')::boolean,
          NULLIF(l->>'idl','')::boolean, NULLIF(l->>'sro','')::boolean, NULLIF(l->>'lv','')::boolean, NULLIF(l->>'wa','')::boolean,
          l->>'ada', l->>'dm', NULLIF(l->>'ihd','')::date, l->>'m', l->>'st', l->>'pn', '/listings',
          md5(r.sg_event_id::text || ':' || (l->>'id') || ':' || (l->>'bp') || ':' || (l->>'q')), l, r.aq_short_event_id
        FROM src
        WHERE l->>'id' IS NOT NULL
          -- Wave 3 change-detection: skip if an identical-state snapshot already exists recently
          AND NOT EXISTS (
            SELECT 1 FROM public.seatgeek_listings_snapshots prev
            WHERE prev.sglid = NULLIF(l->>'sglid','')::bigint
              AND prev.sg_event_id = r.sg_event_id
              AND prev.captured_at > now() - interval '70 minutes'
              AND prev.content_hash = md5(r.sg_event_id::text || ':' || (l->>'id') || ':' || (l->>'bp') || ':' || (l->>'q'))
          )
        ON CONFLICT DO NOTHING RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);
    END IF;
    UPDATE public.sg_broker_pending SET resolved_at = now(),
      rows_persisted = CASE WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0) WHEN r.status_code = 429 THEN -429 ELSE -1 END
      WHERE id = r.pending_id;
    IF r.status_code = 200 THEN
      UPDATE public.sg_event_priority_state SET last_polled_listings_at = now() WHERE sg_event_id = r.sg_event_id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;
