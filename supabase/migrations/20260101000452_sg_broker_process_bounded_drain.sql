-- ============================================================================
-- A1 cron-cascade fix (2026-05-17 ~15:00 UTC) — sg_broker_*_process bounded drain.
--
-- Context:
--   - 1,610 unresolved sg_broker_pending rows (scope='listings'), oldest from
--     04:03 UTC. Every fire of sg_priority_listings_process_1min (326 fails/24h)
--     tries to drain the WHOLE backlog through a per-row correlated subquery
--     (SELECT aq_short_event_id FROM aq_event_map WHERE sg_event_id = ...) and
--     hits 2-min statement_timeout, rolling back without committing any
--     UPDATE resolved_at. Next fire re-attempts the same rows. Classic livelock.
--   - bot_chat 268 (A1, 00:19 UTC) declared "cascade cleared" — true at midnight,
--     regressed once 1-min priority crons (PR #186 family) started piling up.
--   - sales scope is healthy (18 unresolved, oldest 15 min) — small payloads.
--
-- Three changes per function (listings + sales mirror):
--   1. NEW PARAM p_limit (default 50): bound work per fire.
--   2. LIFTED JOIN: replace per-row `(SELECT aq_short_event_id ...)` correlated
--      subquery with a LEFT JOIN aq_event_map in the outer FOR-loop SELECT.
--      Same fix for seatgeek_event_xref → populates tevo_event_id on NEW rows
--      (PR #178 backfilled past rows to 87.35%; this stops the bleeding so
--      future rows are born populated).
--   3. ORDER BY p.fired_at: FIFO drain so oldest-first.
--
-- After applying, the 1,610-row backlog drains in ~30 min of normal 1-min cron
-- fires (50/min). New rows arrive at ~5–15/min so the queue stays empty.
--
-- Also unschedules sg_broker_{listings,sales}_process_30min — they call the
-- SAME function as the 1-min priority crons. Keeping the 1-min path only.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sg_broker_listings_process(p_limit int DEFAULT 50)
 RETURNS TABLE(processed integer, listings_persisted integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id,
           h.status_code, h.content::jsonb AS body,
           a.aq_short_event_id,
           x.tevo_event_id
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
          l,
          r.aq_short_event_id
        FROM src WHERE l->>'id' IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);
    END IF;
    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = COALESCE(v_inserted, CASE WHEN r.status_code=200 THEN 0 ELSE -1 END)
      WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

CREATE OR REPLACE FUNCTION public.sg_broker_sales_process(p_limit int DEFAULT 50)
 RETURNS TABLE(processed integer, sales_persisted integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id,
           h.status_code, h.content::jsonb AS body,
           a.aq_short_event_id,
           x.tevo_event_id
    FROM public.sg_broker_pending p
    JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = p.sg_event_id
    LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = p.sg_event_id
    WHERE p.scope = 'sales' AND p.resolved_at IS NULL
    ORDER BY p.fired_at
    LIMIT p_limit
  LOOP
    v_processed := v_processed + 1;
    v_inserted := NULL;
    IF r.status_code = 200 AND jsonb_typeof(r.body->'sales') = 'array' THEN
      WITH src AS (SELECT s FROM jsonb_array_elements(r.body->'sales') AS s),
      ins AS (
        INSERT INTO public.seatgeek_sales_snapshots (
          tevo_event_id, sg_event_id, pulled_at, sg_sale_id,
          broadcast_price, quantity, section, row, stock_type,
          delivery_method, in_hand_date, is_instant, seller_notes,
          sale_at_utc, raw, aq_short_event_id
        )
        SELECT r.tevo_event_id, r.sg_event_id, now(), s->>'id',
          NULLIF(s->>'bp','')::numeric, NULLIF(s->>'q','')::int,
          s->>'s', s->>'r', s->>'st', s->>'dm',
          NULLIF(s->>'ihd','')::date, NULLIF(s->>'idl','')::boolean,
          s->>'pn', NULLIF(s->>'putc','')::timestamptz, s,
          r.aq_short_event_id
        FROM src WHERE s->>'id' IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);
    END IF;
    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = COALESCE(v_inserted, CASE WHEN r.status_code=200 THEN 0 ELSE -1 END)
      WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

-- Unschedule the 30-min variants — redundant with the 1-min priority crons
-- which call the same functions. Keeping both means 32 fires/hour competing
-- for the same backlog with no benefit.
DO $body$
DECLARE v_jobid bigint;
BEGIN
  FOR v_jobid IN
    SELECT jobid FROM cron.job
    WHERE jobname IN ('sg_broker_listings_process_30min','sg_broker_sales_process_30min')
  LOOP
    PERFORM cron.unschedule(v_jobid);
  END LOOP;
END $body$;
