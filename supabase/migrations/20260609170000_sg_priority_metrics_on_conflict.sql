-- Fix: sg_priority_listings_process_5min (jobid 236 → sg_broker_listings_process)
-- was failing on EVERY run with:
--   ERROR: duplicate key value violates unique constraint "seatgeek_event_metrics_dedup"
--   DETAIL: Key (tevo_event_id, captured_at)=(<id>, <now()>) already exists.
--
-- Root cause: the function loops per pending listings row and INSERTs one
-- seatgeek_event_metrics row with captured_at = now(). now() is the TRANSACTION
-- timestamp (constant for the whole function call), and the dedup constraint is
-- UNIQUE (tevo_event_id, captured_at). When a batch (LIMIT 100 ORDER BY fired_at)
-- contains the same tevo_event_id more than once — which happens because the
-- priority poller re-fires the same high-value events every 2 min, so the oldest
-- 100 unresolved pending rows are the same handful of events repeated — the
-- second insert for a repeated tevo_event_id collides and ABORTS the entire batch
-- transaction. No pending row gets resolved_at set, so the same poisoned batch is
-- retried forever and ALL priority events (incl. live NBA Finals games) stop
-- getting SG market metrics, while the general SG poller keeps the rest fresh.
--
-- Fix: add ON CONFLICT (tevo_event_id, captured_at) DO NOTHING to the metrics
-- INSERT — exactly the resilience pattern the listings-snapshots INSERT directly
-- above it already uses. A within-batch duplicate is now skipped (we never want
-- two identical-timestamp metric rows for one event anyway) instead of aborting,
-- so the batch commits, pending rows resolve, and the backlog self-drains.
--
-- SECDEF read/write helper (data-pipeline internal); no signature change, no
-- schema change, no broker-write path touched (CLAUDE.md §1/§2 unaffected).

CREATE OR REPLACE FUNCTION public.sg_broker_listings_process(p_limit integer DEFAULT 50)
 RETURNS TABLE(processed integer, listings_persisted integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id,
           h.status_code, h.content::jsonb AS body,
           a.aq_short_event_id, x.tevo_event_id
    FROM public.sg_broker_pending p
    JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = p.sg_event_id
    LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = p.sg_event_id
    WHERE p.scope = 'listings' AND p.resolved_at IS NULL
    ORDER BY p.fired_at
    LIMIT p_limit
  LOOP
    v_processed := v_processed + 1;
    v_inserted := NULL;
    IF r.status_code = 200 AND jsonb_typeof(r.body->'listings') = 'array' THEN
      WITH src AS (SELECT l FROM jsonb_array_elements(r.body->'listings') AS l),
      ins AS (
        INSERT INTO public.seatgeek_listings_snapshots (
          tevo_event_id, sg_event_id, captured_at,
          sglid, display_id, retail_price_all_in, broadcast_price,
          deal_quality_score, quantity, splits, section, row,
          is_broker_owned, is_b2b, is_instant_download, is_sro,
          has_limited_view, is_wheelchair_acc, ada_details,
          delivery_method, in_hand_date, market_source, stock_type,
          seller_notes, endpoint, content_hash, raw, aq_short_event_id
        )
        SELECT r.tevo_event_id, r.sg_event_id, now(),
          NULLIF(l->>'sglid','')::bigint, l->>'id',
          NULLIF(l->>'pf','')::numeric, NULLIF(l->>'bp','')::numeric,
          NULLIF(l->>'ds','')::numeric, NULLIF(l->>'q','')::int,
          l->'sp', l->>'s', l->>'r',
          NULLIF(l->>'bo','')::boolean, NULLIF(l->>'is_b2b','')::boolean,
          NULLIF(l->>'idl','')::boolean, NULLIF(l->>'sro','')::boolean,
          NULLIF(l->>'lv','')::boolean, NULLIF(l->>'wa','')::boolean,
          l->>'ada', l->>'dm', NULLIF(l->>'ihd','')::date,
          l->>'m', l->>'st', l->>'pn',
          '/listings',
          md5(r.sg_event_id::text || ':' || (l->>'id') || ':' || (l->>'bp') || ':' || (l->>'q')),
          l, r.aq_short_event_id
        FROM src WHERE l->>'id' IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);

      INSERT INTO public.seatgeek_event_metrics (
        sg_event_id, tevo_event_id, captured_at,
        listings_all_count, listings_all_tickets,
        listings_all_min, listings_all_p25, listings_all_median, listings_all_mean,
        listings_all_p75, listings_all_p90, listings_all_max,
        listings_owned_count, listings_owned_tickets,
        listings_owned_min, listings_owned_p25, listings_owned_median, listings_owned_mean,
        listings_owned_p75, listings_owned_p90, listings_owned_max)
      SELECT r.sg_event_id, r.tevo_event_id, now(),
        count(*)::int, coalesce(sum(q),0)::int,
        round(min(bp),2),
        round(percentile_cont(0.25) WITHIN GROUP (ORDER BY bp)::numeric,2),
        round(percentile_cont(0.50) WITHIN GROUP (ORDER BY bp)::numeric,2),
        round(avg(bp),2),
        round(percentile_cont(0.75) WITHIN GROUP (ORDER BY bp)::numeric,2),
        round(percentile_cont(0.90) WITHIN GROUP (ORDER BY bp)::numeric,2),
        round(max(bp),2),
        count(*) FILTER (WHERE bo)::int, coalesce(sum(q) FILTER (WHERE bo),0)::int,
        round(min(bp) FILTER (WHERE bo),2),
        round((percentile_cont(0.25) WITHIN GROUP (ORDER BY bp) FILTER (WHERE bo))::numeric,2),
        round((percentile_cont(0.50) WITHIN GROUP (ORDER BY bp) FILTER (WHERE bo))::numeric,2),
        round(avg(bp) FILTER (WHERE bo),2),
        round((percentile_cont(0.75) WITHIN GROUP (ORDER BY bp) FILTER (WHERE bo))::numeric,2),
        round((percentile_cont(0.90) WITHIN GROUP (ORDER BY bp) FILTER (WHERE bo))::numeric,2),
        round(max(bp) FILTER (WHERE bo),2)
      FROM (
        SELECT NULLIF(l->>'bp','')::numeric AS bp, NULLIF(l->>'q','')::int AS q,
               NULLIF(l->>'bo','')::boolean AS bo
        FROM jsonb_array_elements(r.body->'listings') l
        WHERE l->>'id' IS NOT NULL AND NULLIF(l->>'bp','') IS NOT NULL
      ) lst
      HAVING count(*) > 0
      ON CONFLICT (tevo_event_id, captured_at) DO NOTHING;  -- <<< the fix
    END IF;

    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = CASE
            WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0)
            WHEN r.status_code = 429 THEN -429
            ELSE -1 END
      WHERE id = r.pending_id;

    IF r.status_code = 200
       OR (r.status_code BETWEEN 400 AND 499 AND r.status_code <> 429) THEN
      UPDATE public.sg_event_priority_state
        SET last_polled_listings_at = now()
        WHERE sg_event_id = r.sg_event_id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;
