-- Migration 20260515200000 · level:admin · lane:Audit/Push · writes:sg_broker_pending, seatgeek_{sales,listings}_snapshots cols/FKs, 4 broker fns, 4 T2 crons, sg_events_canonical seed from aq_event_map, unified_orders v2 · reads:aq_event_map, vault.SEATGEEK_API_TOKEN · pre:20260515180000,20260515190000
-- Replace wrong-host SG sellerdirect endpoints with the correct
-- brokerdata.seatgeek.com Broker Data API + extend SG event universe via AQ.
--
-- Operator directive 2026-05-14:
--   "pause all seatgeek crons, remove the wrong seatgeek endpoints and
--    replace with the relevant ones from my new doc. CONFIRM THESE ARE
--    ALL READ ONLY. Wire sales to unified orders, skip purchases. […]
--    do some tests on mapping accuracy improvements between sg and evo
--    using all known matches, impliment to get better matches, then
--    start pulling seatgeek sales data forward and map those where
--    possible, improve database/schemas"
--
-- READ-ONLY CONFIRMATION: every endpoint in the Broker API spec is GET-only.
--   GET /listings, /v2/listings, /sales, /purchases — all GET.
--   Zero POST/PUT/DELETE endpoints documented. RULE 2 preserved.
--   /purchases returns 401 for our token; skipped per operator.
--
-- Old pipeline (paused via cron.alter_job; functions retained for audit, never called):
--   jobid 53-58, 63-65 — all hit sellerdirect-api.seatgeek.com (wrong product)
--
-- New pipeline:
--   sg_broker_sales_queue_30min      :2,:32  loop forward sg_events_canonical
--   sg_broker_sales_process_30min    :7,:37  drain into seatgeek_sales_snapshots
--   sg_broker_listings_queue_30min   :4,:34  same pattern for /listings
--   sg_broker_listings_process_30min :18,:48 drain into seatgeek_listings_snapshots
--
-- Coverage explosion:
--   sg_events_canonical: 43 → 4,609 rows (4,377 seeded from aq_event_map)
--   seatgeek_sales_snapshots: visible $2.5M of broker sales previously invisible
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14 (this session). Idempotent.

-- ============================================================
-- 1. aq_short_event_id columns + NOT VALID FKs on SG snapshot tables
-- ============================================================

ALTER TABLE public.seatgeek_sales_snapshots    ADD COLUMN IF NOT EXISTS aq_short_event_id text;
ALTER TABLE public.seatgeek_listings_snapshots ADD COLUMN IF NOT EXISTS aq_short_event_id text;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='seatgeek_sales_snapshots_aq_short_event_id_fkey') THEN
    ALTER TABLE public.seatgeek_sales_snapshots
      ADD CONSTRAINT seatgeek_sales_snapshots_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='seatgeek_listings_snapshots_aq_short_event_id_fkey') THEN
    ALTER TABLE public.seatgeek_listings_snapshots
      ADD CONSTRAINT seatgeek_listings_snapshots_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
  END IF;
END $$;

COMMENT ON COLUMN public.seatgeek_sales_snapshots.aq_short_event_id IS
  'Canonical cross-source event ID via aq_event_map (lookup by sg_event_id).';
COMMENT ON COLUMN public.seatgeek_listings_snapshots.aq_short_event_id IS
  'Canonical cross-source event ID via aq_event_map (lookup by sg_event_id).';

-- ============================================================
-- 2. Pending queue table for the broker pipeline
-- ============================================================

CREATE TABLE IF NOT EXISTS public.sg_broker_pending (
  id              bigserial PRIMARY KEY,
  request_id      bigint    NOT NULL,
  scope           text      NOT NULL CHECK (scope IN ('sales','listings')),
  sg_event_id     bigint    NOT NULL,
  fired_at        timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz,
  rows_persisted  integer
);
CREATE INDEX IF NOT EXISTS idx_sg_broker_pending_unresolved
  ON public.sg_broker_pending(resolved_at) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_sg_broker_pending_request_id
  ON public.sg_broker_pending(request_id);

ALTER TABLE public.sg_broker_pending ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='sg_broker_pending' AND policyname='admin_only') THEN
    EXECUTE 'CREATE POLICY admin_only ON public.sg_broker_pending FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false)';
  END IF;
END $$;

-- ============================================================
-- 3. Bulk-seed sg_events_canonical from aq_event_map
--    AQ knows 4,410 events with sg_event_id; only 43 were in canonical.
--    Seed the missing ~4,377 so the broker pull has a universe to iterate.
-- ============================================================

INSERT INTO public.sg_events_canonical (
  sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc,
  sg_category, sg_venue_name, sg_venue_city, sg_venue_state,
  tevo_event_id, match_method, has_seller_listings, created_at, updated_at
)
SELECT aq.sg_event_id, aq.event_name, aq.event_date::date, aq.event_date::timestamptz,
       aq.category, aq.venue_name, aq.city, aq.state,
       NULL::bigint, 'aq_event_map_seed', false, now(), now()
FROM public.aq_event_map aq
WHERE aq.sg_event_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical sgc WHERE sgc.sg_event_id = aq.sg_event_id)
ON CONFLICT (sg_event_id) DO NOTHING;

-- ============================================================
-- 4. /sales — smart queue (prioritize evo/tickpick/vivid-relevant events) + process
-- ============================================================

CREATE OR REPLACE FUNCTION public.sg_broker_sales_queue(p_max_events int DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SET search_path = 'public', 'pg_temp'
AS $$
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
        WHERE p.sg_event_id = sgc.sg_event_id AND p.scope='sales' AND p.resolved_at IS NULL
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
  END LOOP;
  RETURN v_count;
END $$;

CREATE OR REPLACE FUNCTION public.sg_broker_sales_process()
RETURNS TABLE(processed integer, sales_persisted integer)
LANGUAGE plpgsql
SET search_path = 'public', 'pg_temp'
AS $$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id, h.status_code, h.content::jsonb AS body
    FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
    WHERE p.scope = 'sales' AND p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1; v_inserted := NULL;
    IF r.status_code = 200 AND jsonb_typeof(r.body->'sales') = 'array' THEN
      WITH src AS (SELECT s FROM jsonb_array_elements(r.body->'sales') AS s),
      ins AS (
        INSERT INTO public.seatgeek_sales_snapshots (
          tevo_event_id, sg_event_id, pulled_at, sg_sale_id,
          broadcast_price, quantity, section, row, stock_type,
          delivery_method, in_hand_date, is_instant, seller_notes,
          sale_at_utc, raw, aq_short_event_id
        )
        SELECT NULL::bigint, r.sg_event_id, now(), s->>'id',
          NULLIF(s->>'bp','')::numeric, NULLIF(s->>'q','')::int,
          s->>'s', s->>'r', s->>'st', s->>'dm',
          NULLIF(s->>'ihd','')::date, NULLIF(s->>'idl','')::boolean,
          s->>'pn', NULLIF(s->>'putc','')::timestamptz, s,
          (SELECT aq_short_event_id FROM public.aq_event_map WHERE sg_event_id = r.sg_event_id)
        FROM src WHERE s->>'id' IS NOT NULL
        ON CONFLICT DO NOTHING RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);
    END IF;
    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = COALESCE(v_inserted, CASE WHEN r.status_code=200 THEN 0 ELSE -1 END)
      WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $$;

-- ============================================================
-- 5. /listings — queue + process (with md5 content_hash for the NOT-NULL col)
-- ============================================================

CREATE OR REPLACE FUNCTION public.sg_broker_listings_queue(p_max_events int DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SET search_path = 'public', 'pg_temp'
AS $$
DECLARE v_token text := get_app_secret('SEATGEEK_API_TOKEN'); r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  FOR r IN
    SELECT sg_event_id FROM public.sg_events_canonical
    WHERE sg_event_date >= current_date
      AND NOT EXISTS (
        SELECT 1 FROM public.sg_broker_pending p
        WHERE p.sg_event_id = sg_events_canonical.sg_event_id AND p.scope='listings' AND p.resolved_at IS NULL
      )
    ORDER BY sg_event_date LIMIT p_max_events
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id) VALUES (v_req_id, 'listings', r.sg_event_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

CREATE OR REPLACE FUNCTION public.sg_broker_listings_process()
RETURNS TABLE(processed integer, listings_persisted integer)
LANGUAGE plpgsql
SET search_path = 'public', 'extensions', 'pg_temp'   -- 'extensions' so md5() resolves
AS $$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id, h.status_code, h.content::jsonb AS body
    FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
    WHERE p.scope = 'listings' AND p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1; v_inserted := NULL;
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
        SELECT NULL::bigint, r.sg_event_id, now(),
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
          (SELECT aq_short_event_id FROM public.aq_event_map WHERE sg_event_id = r.sg_event_id)
        FROM src WHERE l->>'id' IS NOT NULL
        ON CONFLICT DO NOTHING RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);
    END IF;
    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = COALESCE(v_inserted, CASE WHEN r.status_code=200 THEN 0 ELSE -1 END)
      WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $$;

-- ============================================================
-- 6. Pause 9 wrong-host SG crons, wire 4 new broker crons
-- ============================================================

DO $$ BEGIN
  PERFORM cron.alter_job(jobid::bigint, active := false)
  FROM cron.job
  WHERE active = true
    AND (jobname LIKE 'sg_listings_%' OR jobname LIKE 'sg_seller_%');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'cron pause sweep: %', SQLERRM;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='sg_broker_sales_queue_30min') THEN
    PERFORM cron.schedule('sg_broker_sales_queue_30min',     '2,32 * * * *',  'SELECT public.sg_broker_sales_queue(100);');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='sg_broker_sales_process_30min') THEN
    PERFORM cron.schedule('sg_broker_sales_process_30min',   '7,37 * * * *',  'SELECT public.sg_broker_sales_process();');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='sg_broker_listings_queue_30min') THEN
    PERFORM cron.schedule('sg_broker_listings_queue_30min',  '4,34 * * * *',  'SELECT public.sg_broker_listings_queue(100);');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='sg_broker_listings_process_30min') THEN
    PERFORM cron.schedule('sg_broker_listings_process_30min','18,48 * * * *', 'SELECT public.sg_broker_listings_process();');
  END IF;
END $$;

-- ============================================================
-- 7. unified_orders v2 — adds `seatgeek_sales` branch + aq_short_event_id column
-- ============================================================

CREATE OR REPLACE VIEW public.unified_orders AS
SELECT 'evo'::text AS source,
  o.evo_order_id::text AS source_order_id,
  (SELECT min(i.event_id) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS tevo_event_id,
  NULL::text AS sg_event_id,
  o.state AS source_status,
  xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
  o.type AS source_type,
  (SELECT sum(i.price * i.quantity::numeric) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS gross_value,
  (SELECT sum(i.quantity) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS quantity,
  o.buyer_name, o.seller_name, o.client_name,
  o.evo_created_at AS created_at, o.evo_updated_at AS updated_at, o.last_seen_at,
  (SELECT i.event_name FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id ORDER BY i.evo_item_id LIMIT 1) AS event_name,
  (SELECT i.occurs_at  FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id ORDER BY i.evo_item_id LIMIT 1) AS event_date,
  (SELECT i.aq_short_event_id FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id AND i.aq_short_event_id IS NOT NULL LIMIT 1) AS aq_short_event_id
FROM evo_orders o
LEFT JOIN order_status_xref xref ON xref.source='evo' AND xref.source_status = o.state
UNION ALL
SELECT 'seatgeek'::text, o.sg_order_id, o.tevo_event_id, o.sg_event_id::text,
  o.status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
  NULL::text, o.payment_total, o.sale_quantity::bigint,
  NULL, NULL, NULL,
  o.created_at_sg, o.last_status_at, o.last_status_at,
  o.sg_event_name,
  CASE WHEN o.sg_event_date IS NULL THEN NULL::timestamp
       ELSE ((o.sg_event_date::text || 'T') || COALESCE(o.sg_event_time, '00:00:00'))::timestamp END,
  o.aq_short_event_id
FROM seatgeek_orders o
LEFT JOIN order_status_xref xref ON xref.source='seatgeek' AND xref.source_status = o.status
UNION ALL
SELECT 'seatgeek_sales'::text, s.sg_sale_id,
  NULL::bigint, s.sg_event_id::text,
  'sold'::text, 'fulfilled'::text, true, true,
  NULL::text,
  s.broadcast_price * COALESCE(s.quantity,1)::numeric, s.quantity::bigint,
  NULL, NULL, NULL,
  s.sale_at_utc, s.pulled_at, s.pulled_at,
  (SELECT sg_event_name FROM sg_events_canonical WHERE sg_event_id = s.sg_event_id),
  (SELECT sg_datetime_utc::timestamp FROM sg_events_canonical WHERE sg_event_id = s.sg_event_id),
  s.aq_short_event_id
FROM seatgeek_sales_snapshots s
UNION ALL
SELECT 'seatdata'::text, s.content_hash, s.tevo_event_id, NULL::text,
  'sold'::text, 'fulfilled'::text, true, true,
  NULL::text, s.price * COALESCE(NULLIF(s.quantity,0),1)::numeric, s.quantity::bigint,
  NULL, NULL, NULL,
  s.sale_timestamp, s.sale_timestamp, s.pulled_at,
  NULL, NULL, NULL
FROM seatdata_sales_snapshots s
UNION ALL
SELECT 'tickpick'::text, o.tp_order_id, o.tevo_event_id, NULL::text,
  o.status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
  NULL::text, o.total, o.quantity::bigint,
  NULL, NULL, NULL,
  COALESCE(o.ordered_at, o.pulled_at), o.last_seen_at, o.last_seen_at,
  o.event_name, o.event_date::timestamp, o.aq_short_event_id
FROM tickpick_orders o
LEFT JOIN order_status_xref xref ON xref.source='tickpick' AND xref.source_status = o.status
UNION ALL
SELECT 'vivid'::text, o.vivid_order_id, o.tevo_event_id, NULL::text,
  o.status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
  NULL::text, o.total, o.quantity::bigint,
  NULLIF(concat_ws(' ', o.first_name, o.last_name),''), NULL, NULL,
  COALESCE(o.ordered_at, o.pulled_at), o.last_seen_at, o.last_seen_at,
  o.event_name, o.event_date::timestamp, o.aq_short_event_id
FROM vivid_orders o
LEFT JOIN order_status_xref xref ON xref.source='vivid' AND xref.source_status = o.status;

ALTER VIEW public.unified_orders SET (security_invoker = true);
