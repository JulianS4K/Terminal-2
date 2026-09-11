-- ============================================================================
-- Migration 20260911160500 — OUR PURCHASES: SeatGeek + GoTickets buy-side books,
--                            polled, mapped to TEvo events, joined to the deals
--
-- Lane:     A1 (data plane — two new upstream books) serving D0's deals surface
-- Touches:  seatgeek_purchases, sg_purchases_pending, gotickets_purchases,
--           gt_purchases_pending (CREATE TABLE) ·
--           sg_purchases_sync(timestamptz,timestamptz,int,int), sg_purchases_sync(),
--           sg_purchases_drain(), gt_purchases_sync(timestamptz,timestamptz),
--           gt_purchases_sync(), gt_purchases_drain(), our_purchases_map() (CREATE FUNCTION) ·
--           v_our_purchases, v_our_purchase_flips, v_our_purchase_deals (CREATE VIEW) ·
--           cron_policy (+4 rows), cron.job (4 jobs)
--           Reads: sg_events_canonical, aq_event_map, gotickets_event, v_s4kcs_orders,
--           order_fee_schedule, gotickets_deals_feed, gotickets_deal_outcome
-- Pre-reqs: 20260909220000 (gotickets_sales pattern + vault GOTICKETS_*),
--           20260910200000 (get_app_secret('SEATGEEK_API_TOKEN') pattern),
--           20260911160400 (gotickets_deal_outcome), vault secrets
--           SEATGEEK_API_TOKEN / GOTICKETS_ACCESS_ID / GOTICKETS_API_SECRET
--
-- ⚠ READ-ONLY UPSTREAM (RULE 2). Two calls, both GET, both on already-allowlisted
-- broker hosts:  GET https://brokerdata.seatgeek.com/purchases
--                GET https://sc.gotickets.com/rest/purchases
-- These fetch RECORDS of purchases we already made. Nothing here buys, holds,
-- or mutates anything at either marketplace. No *_client.py guard is touched
-- (gotickets_client.get_purchases / seatgeek_client.purchases are GET-only
-- wrappers of the same two routes for ad-hoc use).
--
-- WHY (operator direction 2026-09-11: "purchasing as in what we're buying, not
-- auto buying" · "seatgeek purchase, api, plug in, pool map and make polling
-- cron"). The deal feed now has an outcome label (mig 20260911160400) built from
-- MARKET clearing prices. The label we actually want to calibrate against is our
-- OWN flips: what we paid, what we later sold it for. Step one is a durable,
-- polled record of what we bought. Step two (here too) maps each purchase to
-- the TEvo event through the hub and joins it to (a) our CRM sales — the flip —
-- and (b) the deal feed — did we buy a flagged deal, and how did it grade.
--
-- ── Endpoint shapes (from the operator-supplied specs) ─────────────────────
-- SeatGeek /purchases?token&start_time&end_time&event_id&order_ids&order_status
--   &page&per_page → {meta:{page,per_page,status,total}, purchases:[{event:{id,
--   location,name,start_data,type}, order_id, order_status, payment:{price,fees,
--   tax,delivery,total}, quantity, sale_date, tickets:[{section,row,seat,ga,
--   is_ada,obstructed_view, barcode:{type,value}, mobile_passes:[{type,url}]}]}]}
--   PAGED: the drain queues page+1 while page*per_page < meta.total (cap 50 pages
--   per window). per_page defaults to 10 — the client observed that as the max.
--   ⚠ Historically this route was SCOPE-DENIED (401) for our token
--   (seatgeek_client.py note). The pending row records http_status per pull, so
--   a denial is visible in sg_purchases_pending rather than silently empty.
-- GoTickets /rest/purchases?orderTimeFrom&orderTimeTo (both REQUIRED, ISO-8601)
--   → [{id, createTime, orderTotal, orderStatus, quantity, section, originalSection,
--   row, lowSeat, highSeat, notes, inHandDate, event:{id,name,venueId,venueName,
--   venueCity,venueState,eventTimeLocal,eventTimeUtc,performers[],status},
--   deliveryMethod, stockType, cancelReason, fulfilled, fulfillmentMethod,
--   fulfillmentTime, transferSource, purchasingUserEmail, recipient{…PII},
--   accountLogin/accountPassword/accountUrl, transferUrls[], files[{base64}],
--   shippingLabel{…}}]
--
-- ⚠ REDACTION IS MANDATORY, NOT OPTIONAL. Both payloads carry things that must
-- never sit in a broadly-readable table: SeatGeek ticket BARCODES + wallet-pass
-- URLs; GoTickets recipient PII, transfer ACCOUNT CREDENTIALS, transfer URLs,
-- base64 file attachments, shipping labels. The drains strip every one of those
-- keys before the row is stored — `raw` here is the REDACTED document. If a
-- future need arises for barcodes, that is a separate, RLS-scoped table.
--
-- ── Price bases (PROJECT_BIBLE §3 landmine class) ───────────────────────────
-- SeatGeek payment.price is the ORDER ticket subtotal; total = price+fees+tax+
-- delivery, all ORDER-level. GoTickets orderTotal is the ORDER total. Both are
-- normalised to per-ticket in v_our_purchases (unit_price = tickets only,
-- unit_all_in = what we actually paid per seat). Read those, not the raw fields.
--
-- ── Mapping (§0: the hub is THE join) ───────────────────────────────────────
-- SeatGeek event id → tevo via sg_events_canonical (9,224 mapped) then
-- aq_event_map.sg_event_id (11,493). GoTickets event id → tevo via
-- gotickets_event.tevo_event_id (5,068) then aq_event_map.gotickets_event_id
-- (6,368). our_purchases_map() re-runs on every drain so purchases mapped late
-- (as the AQ bridge fills) pick up their tevo id; `mapped_via` records which
-- resolver won. Unmapped rows are counted in the drain result — those are the
-- mapping agent's queue, not this migration's job.
--
-- ROLLBACK: cron.unschedule ×4 (sg_purchases_sync_30min, sg_purchases_drain_30min,
--           gt_purchases_sync_30min, gt_purchases_drain_30min); DELETE the 4
--           cron_policy rows; DROP VIEW v_our_purchase_deals, v_our_purchase_flips,
--           v_our_purchases; DROP FUNCTION our_purchases_map, gt_purchases_drain,
--           gt_purchases_sync(), gt_purchases_sync(timestamptz,timestamptz),
--           sg_purchases_drain, sg_purchases_sync(), sg_purchases_sync(timestamptz,
--           timestamptz,int,int); DROP TABLE gt_purchases_pending, gotickets_purchases,
--           sg_purchases_pending, seatgeek_purchases.
-- ============================================================================

-- ── 1. SeatGeek buy-side book ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.seatgeek_purchases (
  order_id          text        PRIMARY KEY,
  sg_event_id       bigint,
  event_name        text,
  event_location    text,
  event_start       timestamp,                 -- as sent (local wall clock, "start_data")
  event_type        text,                      -- e.g. ncaa_football
  order_status      text,
  quantity          int,
  sale_date         timestamptz,               -- when WE bought
  payment_price     numeric,                   -- ORDER ticket subtotal
  payment_fees      numeric,
  payment_tax       numeric,
  payment_delivery  numeric,
  payment_total     numeric,                   -- ORDER all-in
  section           text,                      -- first ticket's section
  "row"             text,                      -- first ticket's row
  seats             text[],                    -- all ticket seats
  n_sections        int,                       -- distinct sections across tickets (split orders)
  tickets           jsonb,                     -- REDACTED: section/row/seat/ga/is_ada/obstructed_view only
  raw               jsonb,                     -- REDACTED document
  tevo_event_id     bigint,
  mapped_via        text,
  pulled_at         timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sg_purchases_event ON public.seatgeek_purchases (sg_event_id);
CREATE INDEX IF NOT EXISTS idx_sg_purchases_tevo  ON public.seatgeek_purchases (tevo_event_id);
CREATE INDEX IF NOT EXISTS idx_sg_purchases_sale  ON public.seatgeek_purchases (sale_date DESC);
ALTER TABLE public.seatgeek_purchases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.seatgeek_purchases FROM PUBLIC, anon;
GRANT SELECT ON public.seatgeek_purchases TO authenticated, service_role;
COMMENT ON TABLE public.seatgeek_purchases IS
  'Our SeatGeek BUY-side book (GET brokerdata /purchases). One row per order we placed. payment_* are ORDER-level; read v_our_purchases for per-ticket. tickets/raw are REDACTED (no barcodes, no wallet URLs). tevo_event_id via sg_events_canonical then aq_event_map. A1 mig 20260911160500.';

CREATE TABLE IF NOT EXISTS public.sg_purchases_pending (
  request_id     bigint      PRIMARY KEY,
  fired_at       timestamptz NOT NULL DEFAULT now(),
  start_time     timestamptz,
  end_time       timestamptz,
  page           int         NOT NULL DEFAULT 1,
  per_page       int         NOT NULL DEFAULT 10,
  resolved_at    timestamptz,
  http_status    int,
  meta_total     int,
  rows_persisted int,
  error_msg      text
);
REVOKE ALL ON public.sg_purchases_pending FROM PUBLIC, anon;
GRANT SELECT ON public.sg_purchases_pending TO service_role;
COMMENT ON TABLE public.sg_purchases_pending IS
  'pg_net request ledger for sg_purchases_sync/drain. http_status is stored so a scope-denied (401) token is visible here. A1 mig 20260911160500.';

-- ── 2. GoTickets buy-side book ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.gotickets_purchases (
  gt_purchase_id     bigint      PRIMARY KEY,
  create_time        timestamptz,               -- when WE bought
  order_total        numeric,                   -- ORDER total
  order_status       text,
  cancel_reason      text,
  quantity           int,
  section            text,                      -- zoned label, e.g. "Infield Box 135"
  original_section   text,                      -- bare section, e.g. "135"
  "row"              text,
  low_seat           text,
  high_seat          text,
  notes              text,
  in_hand_date       date,
  gt_event_id        bigint,
  event_name         text,
  venue_id           bigint,
  venue_name         text,
  venue_city         text,
  venue_state        text,
  event_time_local   timestamp,
  event_time_utc     timestamptz,
  event_status       text,
  performers         jsonb,
  delivery_method    text,
  stock_type         text,
  fulfilled          boolean,
  fulfillment_method text,
  fulfillment_time   timestamptz,
  transfer_source    text,
  purchasing_user    text,                      -- purchasingUserEmail (ours, operational)
  raw                jsonb,                     -- REDACTED document
  tevo_event_id      bigint,
  mapped_via         text,
  pulled_at          timestamptz NOT NULL DEFAULT now(),
  last_seen_at       timestamptz NOT NULL DEFAULT now(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_gt_purchases_event ON public.gotickets_purchases (gt_event_id);
CREATE INDEX IF NOT EXISTS idx_gt_purchases_tevo  ON public.gotickets_purchases (tevo_event_id);
CREATE INDEX IF NOT EXISTS idx_gt_purchases_time  ON public.gotickets_purchases (create_time DESC);
ALTER TABLE public.gotickets_purchases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gotickets_purchases FROM PUBLIC, anon;
GRANT SELECT ON public.gotickets_purchases TO authenticated, service_role;
COMMENT ON TABLE public.gotickets_purchases IS
  'Our GoTickets BUY-side book (GET sc.gotickets.com/rest/purchases). One row per order we placed. order_total is ORDER-level; read v_our_purchases for per-ticket. raw is REDACTED (no recipient, no account credentials, no transfer URLs, no files, no shipping label). tevo_event_id via gotickets_event then aq_event_map. A1 mig 20260911160500.';

CREATE TABLE IF NOT EXISTS public.gt_purchases_pending (
  request_id     bigint      PRIMARY KEY,
  fired_at       timestamptz NOT NULL DEFAULT now(),
  time_from      timestamptz,
  time_to        timestamptz,
  resolved_at    timestamptz,
  http_status    int,
  rows_persisted int,
  error_msg      text
);
REVOKE ALL ON public.gt_purchases_pending FROM PUBLIC, anon;
GRANT SELECT ON public.gt_purchases_pending TO service_role;

-- ── 3. Mapping (hub first) ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.our_purchases_map()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_sg int := 0; v_gt int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  WITH m AS (
    SELECT p.order_id,
           coalesce(c.tevo_event_id, a.tevo_event_id) AS tevo,
           CASE WHEN c.tevo_event_id IS NOT NULL THEN 'sg_events_canonical'
                WHEN a.tevo_event_id IS NOT NULL THEN 'aq_event_map' END AS via
    FROM public.seatgeek_purchases p
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.sg_events_canonical x
                        WHERE x.sg_event_id = p.sg_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) c ON true
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.aq_event_map x
                        WHERE x.sg_event_id = p.sg_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) a ON true
    WHERE p.tevo_event_id IS NULL AND p.sg_event_id IS NOT NULL
  ), u AS (
    UPDATE public.seatgeek_purchases p SET tevo_event_id = m.tevo, mapped_via = m.via, updated_at = now()
    FROM m WHERE m.order_id = p.order_id AND m.tevo IS NOT NULL RETURNING 1
  ) SELECT count(*) INTO v_sg FROM u;

  WITH m AS (
    SELECT p.gt_purchase_id,
           coalesce(g.tevo_event_id, a.tevo_event_id) AS tevo,
           CASE WHEN g.tevo_event_id IS NOT NULL THEN 'gotickets_event'
                WHEN a.tevo_event_id IS NOT NULL THEN 'aq_event_map' END AS via
    FROM public.gotickets_purchases p
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.gotickets_event x
                        WHERE x.gt_event_id = p.gt_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) g ON true
    LEFT JOIN LATERAL (SELECT tevo_event_id FROM public.aq_event_map x
                        WHERE x.gotickets_event_id = p.gt_event_id AND x.tevo_event_id IS NOT NULL LIMIT 1) a ON true
    WHERE p.tevo_event_id IS NULL AND p.gt_event_id IS NOT NULL
  ), u AS (
    UPDATE public.gotickets_purchases p SET tevo_event_id = m.tevo, mapped_via = m.via, updated_at = now()
    FROM m WHERE m.gt_purchase_id = p.gt_purchase_id AND m.tevo IS NOT NULL RETURNING 1
  ) SELECT count(*) INTO v_gt FROM u;

  RETURN jsonb_build_object(
    'sg_mapped_now', v_sg, 'gt_mapped_now', v_gt,
    'sg_unmapped', (SELECT count(*) FROM public.seatgeek_purchases WHERE tevo_event_id IS NULL),
    'gt_unmapped', (SELECT count(*) FROM public.gotickets_purchases WHERE tevo_event_id IS NULL));
END $fn$;
REVOKE ALL ON FUNCTION public.our_purchases_map() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.our_purchases_map() TO service_role;
COMMENT ON FUNCTION public.our_purchases_map() IS
  'Fill tevo_event_id on unmapped purchases: SeatGeek via sg_events_canonical then aq_event_map.sg_event_id; GoTickets via gotickets_event then aq_event_map.gotickets_event_id. Idempotent; run by every drain. A1 mig 20260911160500.';

-- ── 4. SeatGeek: fire + drain ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sg_purchases_sync(
  p_start timestamptz, p_end timestamptz, p_page int DEFAULT 1, p_per_page int DEFAULT 10)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_req bigint;
  v_fmt constant text := 'YYYY-MM-DD"T"HH24:MI:SS';
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF v_token IS NULL OR v_token = '' THEN RETURN NULL; END IF;

  -- Token in the query string: brokerdata's own convention (every sales/listings
  -- poller in this repo does the same). GET only — a purchase RECORD, not a purchase.
  SELECT net.http_get(
    url := 'https://brokerdata.seatgeek.com/purchases?token=' || v_token
           || '&start_time=' || to_char(p_start AT TIME ZONE 'utc', v_fmt)
           || '&end_time='   || to_char(p_end   AT TIME ZONE 'utc', v_fmt)
           || '&page=' || GREATEST(p_page, 1)::text
           || '&per_page=' || LEAST(GREATEST(p_per_page, 1), 100)::text,
    timeout_milliseconds := 30000
  ) INTO v_req;
  INSERT INTO public.sg_purchases_pending (request_id, start_time, end_time, page, per_page)
  VALUES (v_req, p_start, p_end, GREATEST(p_page, 1), LEAST(GREATEST(p_per_page, 1), 100));
  RETURN v_req;
END $fn$;

-- Incremental wrapper: from the newest purchase we hold (minus a 3-day overlap so
-- late status changes are re-read), or 90 days back on first run, to now.
CREATE OR REPLACE FUNCTION public.sg_purchases_sync()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_from timestamptz;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(max(sale_date) - interval '3 days', now() - interval '90 days')
    INTO v_from FROM public.seatgeek_purchases;
  RETURN public.sg_purchases_sync(v_from, now(), 1, 10);
END $fn$;

CREATE OR REPLACE FUNCTION public.sg_purchases_drain()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  r RECORD; j jsonb; v_batch int; v_rows int := 0; v_resolved int := 0; v_next int := 0;
  v_total int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  FOR r IN
    SELECT s.request_id, s.start_time, s.end_time, s.page, s.per_page,
           resp.status_code, resp.content, resp.error_msg
    FROM public.sg_purchases_pending s
    JOIN net._http_response resp ON resp.id = s.request_id
    WHERE s.resolved_at IS NULL
    ORDER BY s.fired_at
  LOOP
    v_batch := 0; v_total := NULL;
    IF r.status_code = 200 AND r.content IS NOT NULL AND left(ltrim(r.content), 1) = '{' THEN
      j := r.content::jsonb;
      v_total := NULLIF(j->'meta'->>'total', '')::int;
      WITH src AS (
        SELECT e FROM jsonb_array_elements(coalesce(j->'purchases', '[]'::jsonb)) AS e
        WHERE (e->>'order_id') IS NOT NULL
      ),
      tix AS (  -- REDACT: keep seat geometry, drop barcode + mobile_passes
        SELECT s.e->>'order_id' AS oid,
               jsonb_agg(t - 'barcode' - 'mobile_passes') AS tickets,
               (array_agg(t->>'section' ORDER BY ord))[1] AS section,
               (array_agg(t->>'row'     ORDER BY ord))[1] AS "row",
               array_agg(t->>'seat' ORDER BY ord) FILTER (WHERE t->>'seat' IS NOT NULL) AS seats,
               count(DISTINCT t->>'section') AS n_sections
        FROM src s
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.e->'tickets', '[]'::jsonb)) WITH ORDINALITY AS x(t, ord)
        GROUP BY s.e->>'order_id'
      ),
      up AS (
        INSERT INTO public.seatgeek_purchases AS p (
          order_id, sg_event_id, event_name, event_location, event_start, event_type,
          order_status, quantity, sale_date,
          payment_price, payment_fees, payment_tax, payment_delivery, payment_total,
          section, "row", seats, n_sections, tickets, raw, pulled_at, last_seen_at, updated_at)
        SELECT s.e->>'order_id',
               NULLIF(s.e->'event'->>'id', '')::bigint,
               s.e->'event'->>'name', s.e->'event'->>'location',
               NULLIF(s.e->'event'->>'start_data', '')::timestamp,
               s.e->'event'->>'type',
               s.e->>'order_status',
               NULLIF(s.e->>'quantity', '')::int,
               NULLIF(s.e->>'sale_date', '')::timestamptz,
               NULLIF(s.e->'payment'->>'price', '')::numeric,
               NULLIF(s.e->'payment'->>'fees', '')::numeric,
               NULLIF(s.e->'payment'->>'tax', '')::numeric,
               NULLIF(s.e->'payment'->>'delivery', '')::numeric,
               NULLIF(s.e->'payment'->>'total', '')::numeric,
               t.section, t."row", t.seats, t.n_sections, t.tickets,
               (s.e - 'tickets') || jsonb_build_object('tickets', coalesce(t.tickets, '[]'::jsonb)),
               now(), now(), now()
        FROM src s LEFT JOIN tix t ON t.oid = s.e->>'order_id'
        ON CONFLICT (order_id) DO UPDATE SET
          order_status = EXCLUDED.order_status, quantity = EXCLUDED.quantity,
          payment_price = EXCLUDED.payment_price, payment_fees = EXCLUDED.payment_fees,
          payment_tax = EXCLUDED.payment_tax, payment_delivery = EXCLUDED.payment_delivery,
          payment_total = EXCLUDED.payment_total,
          section = EXCLUDED.section, "row" = EXCLUDED."row", seats = EXCLUDED.seats,
          n_sections = EXCLUDED.n_sections, tickets = EXCLUDED.tickets, raw = EXCLUDED.raw,
          last_seen_at = now(), updated_at = now()
        RETURNING 1)
      SELECT count(*) INTO v_batch FROM up;

      -- Page on while the window has more (bounded: 50 pages per window).
      IF v_total IS NOT NULL AND r.page * r.per_page < v_total AND r.page < 50 THEN
        PERFORM public.sg_purchases_sync(r.start_time, r.end_time, r.page + 1, r.per_page);
        v_next := v_next + 1;
      END IF;
    END IF;

    UPDATE public.sg_purchases_pending
       SET resolved_at = now(), http_status = r.status_code, meta_total = v_total,
           rows_persisted = v_batch,
           error_msg = CASE WHEN r.status_code = 200 THEN NULL
                            ELSE left(coalesce(r.error_msg, r.content), 300) END
     WHERE request_id = r.request_id;
    v_rows := v_rows + v_batch; v_resolved := v_resolved + 1;
  END LOOP;

  RETURN jsonb_build_object('resolved', v_resolved, 'rows', v_rows, 'next_pages_queued', v_next)
         || public.our_purchases_map();
END $fn$;

REVOKE ALL ON FUNCTION public.sg_purchases_sync(timestamptz,timestamptz,int,int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sg_purchases_sync() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sg_purchases_drain() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sg_purchases_sync(timestamptz,timestamptz,int,int) TO service_role;
GRANT EXECUTE ON FUNCTION public.sg_purchases_sync() TO service_role;
GRANT EXECUTE ON FUNCTION public.sg_purchases_drain() TO service_role;
COMMENT ON FUNCTION public.sg_purchases_sync(timestamptz,timestamptz,int,int) IS
  'Queue GET brokerdata /purchases for a [start,end] window + page (pg_net). Read-only. A1 mig 20260911160500.';
COMMENT ON FUNCTION public.sg_purchases_drain() IS
  'Parse queued /purchases responses into seatgeek_purchases (REDACTED tickets), page on while meta.total says more, then our_purchases_map(). A1 mig 20260911160500.';

-- ── 5. GoTickets: fire + drain ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.gt_purchases_sync(p_from timestamptz, p_to timestamptz)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_req bigint;
  v_fmt constant text := 'YYYY-MM-DD"T"HH24:MI:SS"Z"';
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  -- pg_net does not URL-encode: escape the colons in the ISO timestamps.
  SELECT net.http_get(
    url := 'https://sc.gotickets.com/rest/purchases'
           || '?orderTimeFrom=' || replace(to_char(p_from AT TIME ZONE 'utc', v_fmt), ':', '%3A')
           || '&orderTimeTo='   || replace(to_char(p_to   AT TIME ZONE 'utc', v_fmt), ':', '%3A'),
    headers := jsonb_build_object(
      'X-Api-Access-Id',     trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'GOTICKETS_ACCESS_ID')),
      'X-Api-Access-Secret', trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'GOTICKETS_API_SECRET')),
      'Accept', 'application/json'),
    timeout_milliseconds := 120000
  ) INTO v_req;
  INSERT INTO public.gt_purchases_pending (request_id, time_from, time_to) VALUES (v_req, p_from, p_to);
  RETURN v_req;
END $fn$;

CREATE OR REPLACE FUNCTION public.gt_purchases_sync()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_from timestamptz;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(max(create_time) - interval '3 days', now() - interval '90 days')
    INTO v_from FROM public.gotickets_purchases;
  RETURN public.gt_purchases_sync(v_from, now());
END $fn$;

CREATE OR REPLACE FUNCTION public.gt_purchases_drain()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE r RECORD; v_batch int; v_rows int := 0; v_resolved int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '120000', true);

  FOR r IN
    SELECT s.request_id, resp.status_code, resp.content, resp.error_msg
    FROM public.gt_purchases_pending s
    JOIN net._http_response resp ON resp.id = s.request_id
    WHERE s.resolved_at IS NULL
    ORDER BY s.fired_at
  LOOP
    v_batch := 0;
    IF r.status_code = 200 AND r.content IS NOT NULL AND left(ltrim(r.content), 1) = '[' THEN
      WITH src AS (
        SELECT e FROM jsonb_array_elements(r.content::jsonb) AS e WHERE (e->>'id') IS NOT NULL
      ),
      up AS (
        INSERT INTO public.gotickets_purchases AS p (
          gt_purchase_id, create_time, order_total, order_status, cancel_reason, quantity,
          section, original_section, "row", low_seat, high_seat, notes, in_hand_date,
          gt_event_id, event_name, venue_id, venue_name, venue_city, venue_state,
          event_time_local, event_time_utc, event_status, performers,
          delivery_method, stock_type, fulfilled, fulfillment_method, fulfillment_time,
          transfer_source, purchasing_user, raw, pulled_at, last_seen_at, updated_at)
        SELECT (e->>'id')::bigint,
               NULLIF(e->>'createTime', '')::timestamptz,
               NULLIF(e->>'orderTotal', '')::numeric,
               e->>'orderStatus', NULLIF(e->>'cancelReason', ''),
               NULLIF(e->>'quantity', '')::int,
               e->>'section', NULLIF(e->>'originalSection', ''), e->>'row',
               NULLIF(e->>'lowSeat', ''), NULLIF(e->>'highSeat', ''), NULLIF(e->>'notes', ''),
               NULLIF(e->>'inHandDate', '')::date,
               NULLIF(e->'event'->>'id', '')::bigint,
               e->'event'->>'name',
               NULLIF(e->'event'->>'venueId', '')::bigint,
               e->'event'->>'venueName', e->'event'->>'venueCity', e->'event'->>'venueState',
               NULLIF(e->'event'->>'eventTimeLocal', '')::timestamp,
               NULLIF(e->'event'->>'eventTimeUtc', '')::timestamptz,
               e->'event'->>'status',
               e->'event'->'performers',
               e->>'deliveryMethod', e->>'stockType',
               NULLIF(e->>'fulfilled', '')::boolean,
               e->>'fulfillmentMethod',
               NULLIF(e->>'fulfillmentTime', '')::timestamptz,
               e->>'transferSource', e->>'purchasingUserEmail',
               -- REDACT: PII, transfer credentials, attachments, labels.
               e - 'recipient' - 'accountUrl' - 'accountLogin' - 'accountPassword'
                 - 'transferUrls' - 'files' - 'shippingLabel'
                 - 'customerPickupContactName' - 'customerPickupContactPhone',
               now(), now(), now()
        FROM src
        ON CONFLICT (gt_purchase_id) DO UPDATE SET
          order_status = EXCLUDED.order_status, cancel_reason = EXCLUDED.cancel_reason,
          order_total = EXCLUDED.order_total, quantity = EXCLUDED.quantity,
          fulfilled = EXCLUDED.fulfilled, fulfillment_method = EXCLUDED.fulfillment_method,
          fulfillment_time = EXCLUDED.fulfillment_time, in_hand_date = EXCLUDED.in_hand_date,
          event_status = EXCLUDED.event_status, raw = EXCLUDED.raw,
          last_seen_at = now(), updated_at = now()
        RETURNING 1)
      SELECT count(*) INTO v_batch FROM up;
    END IF;

    UPDATE public.gt_purchases_pending
       SET resolved_at = now(), http_status = r.status_code, rows_persisted = v_batch,
           error_msg = CASE WHEN r.status_code = 200 THEN NULL
                            ELSE left(coalesce(r.error_msg, r.content), 300) END
     WHERE request_id = r.request_id;
    v_rows := v_rows + v_batch; v_resolved := v_resolved + 1;
  END LOOP;

  RETURN jsonb_build_object('resolved', v_resolved, 'rows', v_rows) || public.our_purchases_map();
END $fn$;

REVOKE ALL ON FUNCTION public.gt_purchases_sync(timestamptz,timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gt_purchases_sync() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gt_purchases_drain() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gt_purchases_sync(timestamptz,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.gt_purchases_sync() TO service_role;
GRANT EXECUTE ON FUNCTION public.gt_purchases_drain() TO service_role;
COMMENT ON FUNCTION public.gt_purchases_sync(timestamptz,timestamptz) IS
  'Queue GET sc.gotickets.com/rest/purchases?orderTimeFrom&orderTimeTo (both required; pg_net). Read-only. A1 mig 20260911160500.';
COMMENT ON FUNCTION public.gt_purchases_drain() IS
  'Parse queued /rest/purchases responses into gotickets_purchases (REDACTED raw), then our_purchases_map(). A1 mig 20260911160500.';

-- ── 6. Unified buy-side view, per-ticket, hub-mapped ─────────────────────────
CREATE OR REPLACE VIEW public.v_our_purchases
WITH (security_invoker = true) AS
SELECT 'seatgeek'::text                       AS source,
       p.order_id                             AS purchase_id,
       p.tevo_event_id, p.mapped_via,
       p.sg_event_id::text                    AS source_event_id,
       p.event_name,
       p.event_start::date                    AS event_date,
       p.section,
       (regexp_match(p.section, '(\d{1,4})'))[1] AS secnum,
       p."row",
       array_to_string(p.seats, ',')          AS seats,
       p.quantity,
       CASE WHEN p.quantity > 0 THEN round(p.payment_price / p.quantity, 2) END AS unit_price,
       CASE WHEN p.quantity > 0 THEN round(p.payment_total / p.quantity, 2) END AS unit_all_in,
       p.payment_total                        AS order_total,
       p.order_status,
       (p.order_status ~* 'cancel|reject|refund|void')                     AS is_cancelled,
       p.sale_date                            AS purchased_at,
       p.pulled_at, p.last_seen_at
FROM public.seatgeek_purchases p
UNION ALL
SELECT 'gotickets',
       p.gt_purchase_id::text,
       p.tevo_event_id, p.mapped_via,
       p.gt_event_id::text,
       p.event_name,
       coalesce(p.event_time_local::date, (p.event_time_utc AT TIME ZONE 'utc')::date),
       p.section,
       coalesce(NULLIF(p.original_section, ''), (regexp_match(p.section, '(\d{1,4})'))[1]),
       p."row",
       CASE WHEN p.low_seat IS NOT NULL AND p.high_seat IS NOT NULL AND p.low_seat <> p.high_seat
            THEN p.low_seat || '-' || p.high_seat ELSE p.low_seat END,
       p.quantity,
       CASE WHEN p.quantity > 0 THEN round(p.order_total / p.quantity, 2) END,
       CASE WHEN p.quantity > 0 THEN round(p.order_total / p.quantity, 2) END,
       p.order_total,
       p.order_status,
       (p.cancel_reason IS NOT NULL OR p.order_status ~* 'cancel|reject|refund|void'),
       p.create_time,
       p.pulled_at, p.last_seen_at
FROM public.gotickets_purchases p;
GRANT SELECT ON public.v_our_purchases TO authenticated, service_role;
COMMENT ON VIEW public.v_our_purchases IS
  'One buy-side feed: SeatGeek + GoTickets purchases we placed, per-ticket normalised (unit_price = tickets only; unit_all_in = what we paid per seat incl. fees), hub-mapped tevo_event_id, secnum for section joins. A1 mig 20260911160500.';

-- ── 7. The flip: purchase → our later CRM sale, same event × section × row ───
CREATE OR REPLACE VIEW public.v_our_purchase_flips
WITH (security_invoker = true) AS
WITH fee AS (
  SELECT coalesce((SELECT seller_fee_pct FROM public.order_fee_schedule
                    WHERE source = 'sg_seller' ORDER BY effective_from DESC LIMIT 1), 0.10) AS pct
),
sale AS (
  SELECT s.tevo_event_id,
         (regexp_match(s.section, '(\d{1,4})'))[1] AS secnum,
         upper(btrim(s."row"))                     AS row_key,
         s.price_per_ticket, s.source AS sale_source, s.s4k_order_id,
         coalesce(s.purchase_date, s.event_date)   AS sold_on
  FROM public.v_s4kcs_orders s
  WHERE s.tevo_event_id IS NOT NULL AND s.price_per_ticket > 0 AND s.order_status <> 'REJECTED'
)
SELECT p.source, p.purchase_id, p.tevo_event_id, p.event_name, p.event_date,
       p.section, p.secnum, p."row", p.quantity, p.unit_all_in, p.purchased_at, p.is_cancelled,
       count(sa.price_per_ticket)                                            AS sales_matched,
       string_agg(DISTINCT sa.sale_source, ',')                              AS sale_sources,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY sa.price_per_ticket))::numeric, 2) AS sold_med,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY sa.price_per_ticket))::numeric * (1 - fee.pct), 2) AS sold_net_med,
       CASE WHEN p.unit_all_in > 0 AND count(sa.price_per_ticket) > 0 THEN
         round((((percentile_cont(0.5) WITHIN GROUP (ORDER BY sa.price_per_ticket))::numeric * (1 - fee.pct)
                 - p.unit_all_in) / p.unit_all_in * 100), 1) END              AS flip_roi_pct,
       fee.pct                                                                AS seller_fee_pct
FROM public.v_our_purchases p
CROSS JOIN fee
LEFT JOIN sale sa
       ON sa.tevo_event_id = p.tevo_event_id
      AND sa.secnum IS NOT NULL AND sa.secnum = p.secnum
      AND sa.row_key = upper(btrim(p."row"))
      AND sa.sold_on >= p.purchased_at::date
WHERE p.tevo_event_id IS NOT NULL AND NOT p.is_cancelled
GROUP BY p.source, p.purchase_id, p.tevo_event_id, p.event_name, p.event_date,
         p.section, p.secnum, p."row", p.quantity, p.unit_all_in, p.purchased_at, p.is_cancelled, fee.pct;
GRANT SELECT ON public.v_our_purchase_flips TO authenticated, service_role;
COMMENT ON VIEW public.v_our_purchase_flips IS
  'Our own flips: each non-cancelled purchase joined to our CRM sales for the same event x section number x row sold on/after the buy date. flip_roi_pct = (median sold x (1-fee) - unit_all_in) / unit_all_in. The label the deal model should ultimately calibrate against. A1 mig 20260911160500.';

-- ── 8. Did we buy a flagged deal? purchase ↔ feed ↔ outcome label ────────────
CREATE OR REPLACE VIEW public.v_our_purchase_deals
WITH (security_invoker = true) AS
SELECT p.source, p.purchase_id, p.tevo_event_id, p.event_name, p.event_date,
       p.section, p."row", p.quantity, p.unit_all_in, p.purchased_at,
       f.gt_listing_id, f.gt_price AS deal_price, f.first_seen_at AS deal_first_seen_at,
       f.win_prob AS deal_win_prob, f.net_profit_pct AS deal_net_profit_pct,
       f.confidence AS deal_confidence, f.regime AS deal_regime,
       o.outcome AS label_outcome, o.realized_roi_pct AS label_realized_roi_pct,
       o.match_level AS label_match_level
FROM public.v_our_purchases p
JOIN public.gotickets_deals_feed f
  ON f.tevo_event_id = p.tevo_event_id
 AND (regexp_match(f.section, '(\d{1,4})'))[1] = p.secnum
 AND upper(btrim(f."row")) = upper(btrim(p."row"))
 AND f.first_seen_at <= p.purchased_at + interval '1 day'
LEFT JOIN public.gotickets_deal_outcome o
  ON o.tevo_event_id = f.tevo_event_id AND o.gt_listing_id = f.gt_listing_id
WHERE p.tevo_event_id IS NOT NULL;
GRANT SELECT ON public.v_our_purchase_deals TO authenticated, service_role;
COMMENT ON VIEW public.v_our_purchase_deals IS
  'Purchases that match a flagged deal (same event x section number x row, flagged before we bought) with the feed prediction and, once played, the outcome label. Shows which deals we acted on and how they graded. A1 mig 20260911160500.';

-- ── 9. Crons, policy-gated (30-min sync, drain 5 min later) ──────────────────
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, notes)
VALUES
  ('sg_purchases_sync_30min',
   ARRAY[6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 30, 60, NULL, 40,
   'Poll our SeatGeek buy-side book (brokerdata /purchases), incremental window. mig 20260911160500'),
  ('sg_purchases_drain_30min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 5, 5,
   'SELECT EXISTS (SELECT 1 FROM public.sg_purchases_pending WHERE resolved_at IS NULL)', 96,
   'Drain queued /purchases responses; pages on; maps to tevo. mig 20260911160500'),
  ('gt_purchases_sync_30min',
   ARRAY[6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 30, 60, NULL, 40,
   'Poll our GoTickets buy-side book (/rest/purchases), incremental window. mig 20260911160500'),
  ('gt_purchases_drain_30min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 5, 5,
   'SELECT EXISTS (SELECT 1 FROM public.gt_purchases_pending WHERE resolved_at IS NULL)', 96,
   'Drain queued /rest/purchases responses; maps to tevo. mig 20260911160500')
ON CONFLICT (jobname) DO UPDATE SET
  work_check_sql = excluded.work_check_sql, notes = excluded.notes, updated_at = now();

DO $cron$
DECLARE j text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  FOREACH j IN ARRAY ARRAY['sg_purchases_sync_30min','sg_purchases_drain_30min',
                           'gt_purchases_sync_30min','gt_purchases_drain_30min'] LOOP
    PERFORM cron.unschedule(j) WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = j);
  END LOOP;
  PERFORM cron.schedule('sg_purchases_sync_30min', '13,43 * * * *', $body$
    DO $b$ BEGIN IF NOT public.cron_should_fire('sg_purchases_sync_30min') THEN RETURN; END IF;
      PERFORM public.sg_purchases_sync(); END $b$;$body$);
  PERFORM cron.schedule('sg_purchases_drain_30min', '18,48 * * * *', $body$
    DO $b$ BEGIN IF NOT public.cron_should_fire('sg_purchases_drain_30min') THEN RETURN; END IF;
      PERFORM public.sg_purchases_drain(); END $b$;$body$);
  PERFORM cron.schedule('gt_purchases_sync_30min', '14,44 * * * *', $body$
    DO $b$ BEGIN IF NOT public.cron_should_fire('gt_purchases_sync_30min') THEN RETURN; END IF;
      PERFORM public.gt_purchases_sync(); END $b$;$body$);
  PERFORM cron.schedule('gt_purchases_drain_30min', '19,49 * * * *', $body$
    DO $b$ BEGIN IF NOT public.cron_should_fire('gt_purchases_drain_30min') THEN RETURN; END IF;
      PERFORM public.gt_purchases_drain(); END $b$;$body$);
END;
$cron$;
