-- Migration 20260519110000 · lane:A1 · writes:sg_broker_{sales,listings}_{queue,process} + crons · pre:20260519100000 · auth:operator-approved 2026-05-19
--
-- A1 — SG broker pipeline 429-rate-limit awareness + thundering-herd fix.
--
-- BUG (B1 handoff plan in check-this-event-milwaukee-humble-dove.md):
--   Live diagnosis 2026-05-19 confirms 53–69% pct_429 EVERY 30-min cron cycle
--   for the last 24h. SG returns `429 {"message":"API rate limit exceeded"}` with
--   headers:
--     ratelimit-limit: 10
--     ratelimit-remaining: 0
--     retry-after: 8
--   = SG enforces 10 requests per ~8s window per token (~1.25 req/s sustained).
--
-- Operator-caught example: 5/18 Brewers @ Cubs (sg_event_id 17695183) has
-- 422 sales available on SG's /sales endpoint right now, 0 captured in our
-- seatgeek_sales_snapshots table over 5 cron firings since 2026-05-15. Every
-- pending resolved with rows_persisted=-1.
--
-- THREE COMPOUNDING ROOT CAUSES:
--   1. Both sg_broker_listings_queue + sg_broker_sales_queue cron at SAME :04,:34
--      → simultaneous burst of ~100 net.http_get calls competing for 10-req
--      quota. Most 429.
--   2. Queue functions iterate FOR LOOP with no per-request stagger — fires
--      50 parallels back-to-back as fast as pg_net can dispatch.
--   3. Process functions silently bury 429s as `rows_persisted=-1` + mark
--      `resolved_at=now()`. The pending is gone with no distinction between
--      "transient rate limit" and "terminal 4xx".
--
-- THREE-PART FIX:
--
-- Part 1: 429-aware processors. On status_code=429, mark resolved_at=now() +
--         rows_persisted=-429 (distinct sentinel for observability). The
--         resolved-with-failure leaves the pending eligible for re-queue on
--         the next cycle (queue's NOT EXISTS unresolved is satisfied).
--         status=200 → COALESCE(v_inserted, 0). Other non-200 → -1 (terminal).
--
-- Part 2: Per-request stagger. PERFORM pg_sleep(0.9) between fires in both
--         queue functions. ~1.1 req/sec — comfortably under SG's 10/8s ≈
--         1.25 req/sec quota. 50 events × 0.9s = 45s drain.
--
-- Part 3: Cron stagger. Move sg_broker_sales_queue from :04,:34 → :09,:39
--         (5 min offset from listings @ :04,:34). No collision.
--
-- Verification target: pct_429 drops from 53-69% → <10% within 2-3 cron cycles.

-- ============================================================
-- Part 1: 429-aware processors
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_broker_sales_process(p_limit integer DEFAULT 50)
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
    -- A1 2026-05-19: 429-aware sentinel for observability + still resolve so re-queue works
    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = CASE
            WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0)
            WHEN r.status_code = 429 THEN -429   -- rate-limited; next queue cycle will re-fire
            ELSE -1                              -- 400/404/500 terminal failure
          END
      WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

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
    -- A1 2026-05-19: 429-aware sentinel
    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = CASE
            WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0)
            WHEN r.status_code = 429 THEN -429
            ELSE -1
          END
      WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

-- ============================================================
-- Part 2: Queue functions with per-request stagger
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_broker_sales_queue(p_max_events integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_token   text := get_app_secret('SEATGEEK_API_TOKEN');
  r         RECORD;
  v_req_id  bigint;
  v_count   int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  FOR r IN
    WITH events_with_activity AS (
      SELECT DISTINCT aq.sg_event_id, 1 AS priority
      FROM public.evo_order_items i
      JOIN public.aq_event_map aq ON aq.aq_short_event_id = i.aq_short_event_id
      WHERE aq.sg_event_id IS NOT NULL AND i.occurs_at >= now()
      UNION
      SELECT DISTINCT aq.sg_event_id, 2
      FROM (SELECT aq_short_event_id FROM public.tickpick_orders WHERE aq_short_event_id IS NOT NULL
            UNION
            SELECT aq_short_event_id FROM public.vivid_orders    WHERE aq_short_event_id IS NOT NULL) cross_src
      JOIN public.aq_event_map aq ON aq.aq_short_event_id = cross_src.aq_short_event_id
      WHERE aq.sg_event_id IS NOT NULL
    )
    SELECT sgc.sg_event_id, COALESCE(ew.priority, 3) AS priority
    FROM public.sg_events_canonical sgc
    LEFT JOIN events_with_activity ew ON ew.sg_event_id = sgc.sg_event_id
    WHERE sgc.sg_event_date >= current_date
      AND NOT EXISTS (
        SELECT 1 FROM public.sg_broker_pending p
        WHERE p.sg_event_id = sgc.sg_event_id
          AND p.scope = 'sales'
          AND p.resolved_at IS NULL
      )
    ORDER BY priority, sgc.sg_event_date
    LIMIT p_max_events
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id) VALUES (v_req_id, 'sales', r.sg_event_id);
    v_count := v_count + 1;
    -- A1 2026-05-19: stagger 0.9s/req. SG rate limit = 10/8s ≈ 1.25 req/sec.
    -- 0.9s gives ~1.1 req/sec sustained, comfortably under quota.
    -- 50 events × 0.9s = 45s drain — still inside 30-min cron window.
    PERFORM pg_sleep(0.9);
  END LOOP;
  RETURN v_count;
END $function$;

CREATE OR REPLACE FUNCTION public.sg_broker_listings_queue(p_max_events integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_token text := get_app_secret('SEATGEEK_API_TOKEN'); r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  FOR r IN
    SELECT sg_event_id FROM public.sg_events_canonical
    WHERE sg_event_date >= current_date
    ORDER BY sg_event_date LIMIT p_max_events
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id) VALUES (v_req_id, 'listings', r.sg_event_id);
    v_count := v_count + 1;
    -- A1 2026-05-19: stagger 0.9s/req (same rationale as sales_queue)
    PERFORM pg_sleep(0.9);
  END LOOP;
  RETURN v_count;
END $function$;

-- ============================================================
-- Part 3: Stagger sales queue cron from :04,:34 → :09,:39
-- ============================================================
DO $body$ DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sg_broker_sales_queue_30min';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'sg_broker_sales_queue_30min',
    '9,39 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_broker_sales_queue_30min') THEN RETURN; END IF;
      PERFORM public.sg_broker_sales_queue(50);
    END $cronbody$;$cron$
  );
END $body$;

COMMENT ON FUNCTION public.sg_broker_sales_process(integer) IS
  'A1 2026-05-19: 429-aware sentinel (rows_persisted = -429 on rate-limit, -1 on other non-200, COALESCE(v_inserted,0) on 200).';
COMMENT ON FUNCTION public.sg_broker_listings_process(integer) IS
  'A1 2026-05-19: 429-aware sentinel (rows_persisted = -429 on rate-limit, -1 on other non-200).';
COMMENT ON FUNCTION public.sg_broker_sales_queue(integer) IS
  'A1 2026-05-19: 0.9s pg_sleep between fires (~1.1 req/s, under SG 10/8s quota). Cron staggered to :09,:39 to avoid listings collision @ :04,:34.';
COMMENT ON FUNCTION public.sg_broker_listings_queue(integer) IS
  'A1 2026-05-19: 0.9s pg_sleep between fires (~1.1 req/s, under SG 10/8s quota).';
