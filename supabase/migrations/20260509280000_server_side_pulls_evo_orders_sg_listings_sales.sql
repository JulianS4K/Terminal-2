-- ============================================================================
-- Migration 20260509280000 — Migrate Railway-bound crons to Supabase pg_net
--                            + add SG listings windowed cron + SG /sales cron
--
-- Three new server-side data pipelines, all RULE 2 compliant (GET-only via
-- pg_net), all running on Supabase without depending on Railway:
--
-- (a) tevo_sign_get() — HMAC-SHA256-base64 signing for TEvo via pgcrypto.
--     Defensively strips wrapping <...> (left by copy-paste during secret
--     push). Verified live against /v9/orders + /v9/events.
--
-- (b) EVO orders server-side cron — replaces the broken Railway cron 40
--     (terminal-2-production.railway.app/api/admin/collect-orders returns
--     404 — Railway deploy issue). Direct TEvo /v9/orders via pg_net+HMAC.
--
-- (c) SG /v2/listings windowed cron — mirrors TEvo's collect-listings
--     5-window cadence (0-24h every 20m, 1-7d hourly, 7-30d every 4h,
--     30-60d every 12h, 60d+ daily). Persists to seatgeek_listings_snapshots
--     (was empty before this migration).
--
-- (d) SG /sales daily cron — pulls broker-side market sales for SG-linked
--     events. Persists to seatgeek_sales_snapshots (was empty).
--
-- (e) Disables broken Railway-bound evo-orders-collect-10min cron.
--
-- (f) Relaxes NOT NULL on tevo_event_id + sale_at_utc + content_hash where
--     SG response shapes don't always carry them.
-- ============================================================================

-- (a) HMAC-SHA256 helper for TEvo
CREATE OR REPLACE FUNCTION tevo_sign_get(p_path text, p_query text, p_secret text)
RETURNS text AS $$
DECLARE
  v_secret text;
  v_string_to_sign text;
  v_digest bytea;
BEGIN
  -- Defensive: strip wrapping <...> often left by copy-paste
  v_secret := p_secret;
  IF v_secret IS NOT NULL AND length(v_secret) >= 2
     AND substring(v_secret FROM 1 FOR 1) = '<'
     AND substring(v_secret FROM length(v_secret) FOR 1) = '>' THEN
    v_secret := substring(v_secret FROM 2 FOR length(v_secret) - 2);
  END IF;
  v_string_to_sign := 'GET api.ticketevolution.com' || p_path || '?' || coalesce(p_query, '');
  v_digest := hmac(v_string_to_sign::bytea, v_secret::bytea, 'sha256');
  RETURN encode(v_digest, 'base64');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION tevo_sign_get(text, text, text) IS
  'HMAC-SHA256-base64 sign GET to api.ticketevolution.com. Canonical: '
  '"GET host path?query" — ? always present. Strips wrapping <...> from '
  'secret defensively (copy-paste glitch protection).';

-- (b) Schema relaxations for SG listings/sales tables
ALTER TABLE seatgeek_listings_snapshots ALTER COLUMN tevo_event_id DROP NOT NULL;
ALTER TABLE seatgeek_sales_snapshots    ALTER COLUMN tevo_event_id DROP NOT NULL;
ALTER TABLE seatgeek_sales_snapshots    ALTER COLUMN sale_at_utc   DROP NOT NULL;

-- (c) EVO orders pipeline
CREATE TABLE IF NOT EXISTS evo_orders_pending (
  id          bigserial PRIMARY KEY,
  request_id  bigint NOT NULL,
  page        int NOT NULL,
  query_str   text,
  fired_at    timestamptz DEFAULT now(),
  resolved_at timestamptz,
  rows_persisted int
);

CREATE OR REPLACE FUNCTION evo_orders_queue(p_pages int DEFAULT 1)
RETURNS int AS $$
DECLARE
  v_token text := get_app_secret('TEVO_API_TOKEN');
  v_secret text := get_app_secret('TEVO_SECRET');
  v_query text;
  v_sig text;
  v_req_id bigint;
  v_page int;
  v_count int := 0;
BEGIN
  FOR v_page IN 1..p_pages LOOP
    v_query := 'page=' || v_page || '&per_page=10';  -- per_page MAX is 10 server-side
    v_sig := tevo_sign_get('/v9/orders', v_query, v_secret);
    SELECT net.http_get(
      url := 'https://api.ticketevolution.com/v9/orders?' || v_query,
      headers := jsonb_build_object(
        'X-Token', v_token,
        'X-Signature', v_sig,
        'Accept', 'application/vnd.ticketevolution.api+json; version=9'
      ),
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO evo_orders_pending(request_id, page, query_str)
    VALUES (v_req_id, v_page, v_query);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS evo_orders_process();
CREATE FUNCTION evo_orders_process()
RETURNS TABLE(processed int, orders_persisted int, items_persisted int) AS $$
DECLARE
  r RECORD; v_body jsonb; v_orders jsonb;
  v_processed int := 0; v_orders_persisted int := 0;
  v_items_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, h.content, h.status_code
    FROM evo_orders_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      v_orders := COALESCE(v_body->'orders', '[]'::jsonb);
      WITH src AS (SELECT o FROM jsonb_array_elements(v_orders) AS o),
      ins AS (
        INSERT INTO evo_orders (
          evo_order_id, state, type, fraud_check_status,
          total, subtotal, tax, shipping, service_fee, refunded, balance,
          additional_expense, reference, invoice_number, po_number, instructions, partner,
          buyer_id, buyer_name, buyer_brokerage_id, buyer_brokerage_name,
          seller_id, seller_name, seller_brokerage_id, seller_brokerage_name,
          client_id, client_name,
          evo_created_at, evo_updated_at, hold_placed_at, hold_expires_at,
          pulled_at, last_seen_at, raw
        )
        SELECT
          (o->>'id')::bigint,
          o->>'state', o->>'type', o->>'fraud_check_status',
          NULLIF(o->>'total','')::numeric, NULLIF(o->>'subtotal','')::numeric,
          NULLIF(o->>'tax','')::numeric, NULLIF(o->>'shipping','')::numeric,
          NULLIF(o->>'service_fee','')::numeric, NULLIF(o->>'refunded','')::numeric,
          NULLIF(o->>'balance','')::numeric, NULLIF(o->>'additional_expense','')::numeric,
          o->>'reference', o->>'invoice_number', o->>'po_number',
          o->>'instructions', (o->>'partner')::bool,
          NULLIF(o->'buyer'->>'id','')::bigint, o->'buyer'->>'name',
          NULLIF(o->'buyer'->'brokerage'->>'id','')::bigint, o->'buyer'->'brokerage'->>'name',
          NULLIF(o->'seller'->>'id','')::bigint, o->'seller'->>'name',
          NULLIF(o->'seller'->'brokerage'->>'id','')::bigint, o->'seller'->'brokerage'->>'name',
          NULLIF(o->'client'->>'id','')::bigint, o->'client'->>'name',
          NULLIF(o->>'created_at','')::timestamptz, NULLIF(o->>'updated_at','')::timestamptz,
          NULLIF(o->>'hold_placed_at','')::timestamptz, NULLIF(o->>'hold_expires_at','')::timestamptz,
          now(), now(), o
        FROM src WHERE (o->>'id') IS NOT NULL
        ON CONFLICT (evo_order_id) DO UPDATE SET
          state = EXCLUDED.state, type = EXCLUDED.type,
          fraud_check_status = EXCLUDED.fraud_check_status,
          total = EXCLUDED.total, subtotal = EXCLUDED.subtotal,
          shipping = EXCLUDED.shipping, service_fee = EXCLUDED.service_fee,
          refunded = EXCLUDED.refunded, balance = EXCLUDED.balance,
          evo_updated_at = EXCLUDED.evo_updated_at,
          hold_placed_at = EXCLUDED.hold_placed_at, hold_expires_at = EXCLUDED.hold_expires_at,
          last_seen_at = now(), raw = EXCLUDED.raw
        RETURNING 1
      )
      SELECT count(*) INTO v_inserted FROM ins;
      v_orders_persisted := v_orders_persisted + v_inserted;
      UPDATE evo_orders_pending SET resolved_at = now(), rows_persisted = v_inserted
        WHERE id = r.pending_id;
    ELSE
      UPDATE evo_orders_pending SET resolved_at = now(), rows_persisted = -1
        WHERE id = r.pending_id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_orders_persisted, v_items_persisted;
END;
$$ LANGUAGE plpgsql;

-- (d) SG /v2/listings windowed pipeline
CREATE TABLE IF NOT EXISTS sg_listings_pending (
  id          bigserial PRIMARY KEY,
  request_id  bigint NOT NULL,
  sg_event_id bigint NOT NULL,
  window_label text,
  fired_at    timestamptz DEFAULT now(),
  resolved_at timestamptz,
  rows_persisted int
);

CREATE OR REPLACE FUNCTION sg_listings_queue_window(
  p_window text, p_min_age_seconds int, p_limit int DEFAULT 30
) RETURNS int AS $$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  v_min_date date; v_max_date date;
  r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  CASE p_window
    WHEN '0-24h'  THEN v_min_date := current_date;       v_max_date := current_date + 1;
    WHEN '1-7d'   THEN v_min_date := current_date + 1;   v_max_date := current_date + 7;
    WHEN '7-30d'  THEN v_min_date := current_date + 7;   v_max_date := current_date + 30;
    WHEN '30-60d' THEN v_min_date := current_date + 30;  v_max_date := current_date + 60;
    WHEN '60d+'   THEN v_min_date := current_date + 60;  v_max_date := current_date + 365;
    ELSE RAISE EXCEPTION 'unknown window %', p_window;
  END CASE;
  FOR r IN
    SELECT sgc.sg_event_id FROM sg_events_canonical sgc
    LEFT JOIN sg_listings_pending p ON p.sg_event_id = sgc.sg_event_id
        AND p.fired_at > now() - make_interval(secs => p_min_age_seconds)
    WHERE sgc.sg_event_date BETWEEN v_min_date AND v_max_date AND p.id IS NULL
    ORDER BY sgc.sg_event_date LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/v2/listings?event_id=' || r.sg_event_id || '&token=' || v_token,
      timeout_milliseconds := 25000
    ) INTO v_req_id;
    INSERT INTO sg_listings_pending(request_id, sg_event_id, window_label)
    VALUES (v_req_id, r.sg_event_id, p_window);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sg_listings_process()
RETURNS TABLE(processed int, rows_persisted int) AS $$
DECLARE
  r RECORD; v_body jsonb; v_listings jsonb;
  v_processed int := 0; v_persisted int := 0; v_count int;
BEGIN
  FOR r IN
    SELECT p.id, p.request_id, p.sg_event_id, h.content, h.status_code
    FROM sg_listings_pending p JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      v_listings := COALESCE(v_body->'listings', '[]'::jsonb);
      WITH src AS (
        SELECT l, COALESCE(
          (SELECT tevo_event_id FROM seatgeek_event_xref WHERE sg_event_id = r.sg_event_id),
          NULL::bigint
        ) AS tevo_event_id
        FROM jsonb_array_elements(v_listings) AS l
      ),
      ins AS (
        INSERT INTO seatgeek_listings_snapshots (
          tevo_event_id, sg_event_id, captured_at,
          sglid, display_id, retail_price_all_in, broadcast_price,
          deal_quality_score, quantity, splits, section, row,
          is_b2b, is_instant_download, is_sro, has_limited_view, is_wheelchair_acc,
          delivery_method, market_source, stock_type, raw, endpoint, content_hash
        )
        SELECT
          src.tevo_event_id, r.sg_event_id, now(),
          NULLIF(src.l->>'sglid','')::bigint, src.l->>'id',
          (src.l->>'pf')::numeric, (src.l->>'bp')::numeric,
          NULLIF(src.l->>'ds','')::numeric,
          (src.l->>'q')::int, src.l->'sp',
          src.l->>'s', src.l->>'r',
          (src.l->>'is_b2b')::bool, (src.l->>'idl')::bool,
          (src.l->>'sro')::bool, (src.l->>'lv')::bool, (src.l->>'wa')::bool,
          src.l->>'dm', src.l->>'m', src.l->>'st',
          src.l, 'v2/listings',
          encode(digest(
            r.sg_event_id::text || '|' || coalesce(src.l->>'sglid','') || '|' ||
            coalesce(src.l->>'id','') || '|' || coalesce(src.l->>'s','') || '|' ||
            coalesce(src.l->>'r','') || '|' || coalesce(src.l->>'q','') || '|' ||
            coalesce(src.l->>'pf','') || '|' || coalesce(src.l->>'bp',''),
            'sha256'), 'hex')
        FROM src
        RETURNING 1
      )
      SELECT count(*) INTO v_count FROM ins;
      v_persisted := v_persisted + v_count;
      UPDATE sg_listings_pending SET resolved_at = now(), rows_persisted = v_count WHERE id = r.id;
    ELSE
      UPDATE sg_listings_pending SET resolved_at = now(), rows_persisted = -1 WHERE id = r.id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END;
$$ LANGUAGE plpgsql;

-- (e) SG /sales daily pipeline
CREATE TABLE IF NOT EXISTS sg_sales_pending (
  id          bigserial PRIMARY KEY,
  request_id  bigint NOT NULL,
  sg_event_id bigint NOT NULL,
  fired_at    timestamptz DEFAULT now(),
  resolved_at timestamptz,
  rows_persisted int
);

CREATE OR REPLACE FUNCTION sg_sales_queue(p_limit int DEFAULT 30)
RETURNS int AS $$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT sgc.sg_event_id FROM sg_events_canonical sgc
    LEFT JOIN sg_sales_pending p ON p.sg_event_id = sgc.sg_event_id
        AND p.fired_at > now() - interval '20 hours'
    WHERE sgc.sg_event_date BETWEEN current_date - 7 AND current_date + 60 AND p.id IS NULL
    ORDER BY sgc.sg_event_date LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?event_id=' || r.sg_event_id || '&token=' || v_token,
      timeout_milliseconds := 20000
    ) INTO v_req_id;
    INSERT INTO sg_sales_pending(request_id, sg_event_id) VALUES (v_req_id, r.sg_event_id);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.4);
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sg_sales_process()
RETURNS TABLE(processed int, rows_persisted int) AS $$
DECLARE
  r RECORD; v_body jsonb; v_sales jsonb;
  v_processed int := 0; v_persisted int := 0; v_count int;
BEGIN
  FOR r IN
    SELECT p.id, p.request_id, p.sg_event_id, h.content, h.status_code
    FROM sg_sales_pending p JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      v_sales := COALESCE(v_body->'sales', '[]'::jsonb);
      WITH src AS (
        SELECT s, COALESCE(
          (SELECT tevo_event_id FROM seatgeek_event_xref WHERE sg_event_id = r.sg_event_id),
          NULL::bigint
        ) AS tevo_event_id
        FROM jsonb_array_elements(v_sales) AS s
      ),
      ins AS (
        INSERT INTO seatgeek_sales_snapshots (
          tevo_event_id, sg_event_id, pulled_at,
          sg_sale_id, broadcast_price, quantity, section, row,
          stock_type, delivery_method, in_hand_date, is_instant,
          seller_notes, sale_at_utc, raw
        )
        SELECT
          src.tevo_event_id, r.sg_event_id, now(),
          src.s->>'id', (src.s->>'bp')::numeric, (src.s->>'q')::int,
          src.s->>'s', src.s->>'r', src.s->>'st', src.s->>'dm',
          NULLIF(src.s->>'ihd','')::date, (src.s->>'idl')::bool,
          src.s->>'pn', NULLIF(src.s->>'sale_at_utc','')::timestamptz, src.s
        FROM src
        RETURNING 1
      )
      SELECT count(*) INTO v_count FROM ins;
      v_persisted := v_persisted + v_count;
      UPDATE sg_sales_pending SET resolved_at = now(), rows_persisted = v_count WHERE id = r.id;
    ELSE
      UPDATE sg_sales_pending SET resolved_at = now(), rows_persisted = -1 WHERE id = r.id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END;
$$ LANGUAGE plpgsql;

-- (f) Disable broken Railway-bound EVO orders cron
SELECT cron.unschedule('evo-orders-collect-10min');

-- (g) Schedule new server-side crons
SELECT cron.schedule('evo_orders_queue_10min',   '*/10 * * * *',
  $$ SELECT evo_orders_queue(2); $$);
SELECT cron.schedule('evo_orders_process_10min', '1-59/10 * * * *',
  $$ SELECT evo_orders_process(); $$);

-- SG /v2/listings windowed crons matching TEvo's collect-listings cadence
SELECT cron.schedule('sg_listings_0-24h',   '*/20 * * * *',
  $$ SELECT sg_listings_queue_window('0-24h',  1100, 30); $$);
SELECT cron.schedule('sg_listings_1-7d',    '5 * * * *',
  $$ SELECT sg_listings_queue_window('1-7d',   3300, 30); $$);
SELECT cron.schedule('sg_listings_7-30d',   '10 */4 * * *',
  $$ SELECT sg_listings_queue_window('7-30d',  13200, 30); $$);
SELECT cron.schedule('sg_listings_30-60d',  '15 */12 * * *',
  $$ SELECT sg_listings_queue_window('30-60d', 39600, 30); $$);
SELECT cron.schedule('sg_listings_60d+',    '20 2 * * *',
  $$ SELECT sg_listings_queue_window('60d+',   82800, 30); $$);
SELECT cron.schedule('sg_listings_process_5min', '2-59/5 * * * *',
  $$ SELECT sg_listings_process(); $$);

-- SG /sales daily
SELECT cron.schedule('sg_sales_queue_daily',  '30 5 * * *', $$ SELECT sg_sales_queue(60); $$);
SELECT cron.schedule('sg_sales_process_daily','35 5 * * *', $$ SELECT sg_sales_process(); $$);

COMMENT ON FUNCTION evo_orders_queue(int) IS
  'Server-side EVO orders pull via TEvo HMAC + pg_net. Replaces broken '
  'Railway-bound /api/admin/collect-orders cron (was 404). per_page=10 '
  '(server-enforced max).';

COMMENT ON FUNCTION sg_listings_queue_window(text, int, int) IS
  'Server-side SG /v2/listings windowed pull. Mirrors TEvo collect-listings '
  'cadence: 0-24h | 1-7d | 7-30d | 30-60d | 60d+. min_age_seconds dedup.';

COMMENT ON FUNCTION sg_sales_queue(int) IS
  'Server-side SG broker /sales for SG-linked events in -7d..+60d window. '
  'Daily cron fills seatgeek_sales_snapshots (was empty pre-migration).';
