-- ============================================================================
-- Migration 20260911161500 — purchase pollers ride the GoTickets 15-min event cadence
--
-- Lane:     A1 (data plane) serving D0's deals surface
-- Touches:  sg_purchases_sync() (CREATE OR REPLACE), gt_purchases_sync() (CREATE OR REPLACE),
--           sg_purchases_drain() (CREATE OR REPLACE), cron_policy (4 rows renamed),
--           cron.job (unschedule the 4 *_30min jobs, schedule 4 *_15min jobs)
-- Pre-reqs: 20260911160500, 20260911160700, 20260911161300
--
-- Already applied to prod · via MCP 2026-09-11 (operator: "poll sg and go tix purchase
-- apis when you poll goticket events, just account for their respective rate limits").
--
-- CADENCE — the live GoTickets event pull is gt_sales_sync_15min (3,18,33,48) + its drain
-- (8,23,38,53); gt_listings_poll_2min is paused. The two purchase syncs now fire in the
-- same 15-minute cycle, one minute after the GT sales pull, and their drains five minutes
-- later. Minute marks: sync 4,19,34,50 · drain 9,24,39,55. The 50/55 (not 49/54) keep the
-- SeatGeek probe off the sg_sales_poll_5min grid (1-59/4) on the one mark a 15-step
-- sequence would otherwise share with it. cron_policy: peak (06–23 ET) floor 15 min,
-- off-peak 30 min, 80 fires/day; drains stay work-gated (fire only with unresolved rows).
--
-- RATE LIMITS
--   SeatGeek brokerdata: per-TOKEN burst ≈10 req / 8 s, SHARED with a separate prod program
--   (PROJECT_BIBLE §3). So: sg_purchases_sync() queues at most 2 windows per run (was 8;
--   the 90-day backfill takes 15 runs ≈ 4 h instead of 4 runs), still 1 probe while the
--   scope is denied; sg_purchases_drain() queues at most 2 next-pages per run (was
--   unbounded across windows) — every pg_net request is a burst-mate of the listing/sales
--   crons on the same token.
--   GoTickets sc.gotickets.com: no published limit; the client backs off on 429/503 with
--   Retry-After. gt_purchases_sync() queues at most 2 ≤30-day chunks per run (was 6) so a
--   first run is 2 requests beside the sales pull, steady state 1.
--
-- READ-ONLY upstream: GET only. ROLLBACK: re-apply the three bodies from 161300 / 160700 /
-- 160500 and re-run the cron block of 160500 (30-min marks).
-- ============================================================================

-- ── 1. SeatGeek incremental wrapper: ≤2 windows / run ─────────────────────────
CREATE OR REPLACE FUNCTION public.sg_purchases_sync()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  v_from timestamptz; v_to timestamptz; v_req bigint; v_n int := 0; v_max int := 2;
  v_denied boolean;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  -- Scope still denied? (newest 3 resolved pulls all 401 inside 24h) → one probe only.
  SELECT count(*) = 3 INTO v_denied FROM (
    SELECT http_status FROM public.sg_purchases_pending
    WHERE resolved_at > now() - interval '24 hours' ORDER BY resolved_at DESC LIMIT 3) x
  WHERE http_status = 401;
  IF v_denied THEN v_max := 1; END IF;

  -- Never stack on top of windows still in flight (their responses are not drained yet).
  IF EXISTS (SELECT 1 FROM public.sg_purchases_pending
             WHERE resolved_at IS NULL AND fired_at > now() - interval '20 minutes') THEN
    RETURN NULL;
  END IF;

  -- Watermark: latest end_time of a successful pull; first run reaches 90 days back.
  SELECT coalesce(max(end_time), now() - interval '90 days') INTO v_from
  FROM public.sg_purchases_pending WHERE http_status = 200;

  WHILE v_from < now() - interval '1 minute' AND v_n < v_max LOOP
    v_to := LEAST(v_from + interval '72 hours', now());
    v_req := public.sg_purchases_sync(v_from, v_to, 1, 10);
    v_from := v_to; v_n := v_n + 1;
  END LOOP;
  RETURN v_req;
END $fn$;
COMMENT ON FUNCTION public.sg_purchases_sync() IS
  'Incremental SeatGeek purchase pull on the 15-min GT cadence: watermark = latest end_time of a 200 pull (90d back on first run), <= 72h chunks, max 2/run (token burst ≈10 req/8s is shared), 1 probe/run while the last 3 pulls are 401, skips a run while windows are in flight. A1 mig 20260911161500.';

-- ── 2. GoTickets incremental wrapper: ≤2 chunks / run ─────────────────────────
CREATE OR REPLACE FUNCTION public.gt_purchases_sync()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_from timestamptz; v_to timestamptz; v_req bigint; v_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.gt_purchases_pending
             WHERE resolved_at IS NULL AND fired_at > now() - interval '20 minutes') THEN
    RETURN NULL;
  END IF;
  SELECT coalesce(max(create_time) - interval '3 days', now() - interval '90 days')
    INTO v_from FROM public.gotickets_purchases;
  WHILE v_from < now() AND v_n < 2 LOOP
    v_to := LEAST(v_from + interval '30 days' - interval '1 minute', now());
    v_req := public.gt_purchases_sync(v_from, v_to);
    v_from := v_to; v_n := v_n + 1;
  END LOOP;
  RETURN v_req;
END $fn$;
COMMENT ON FUNCTION public.gt_purchases_sync() IS
  'Incremental GoTickets purchase pull on the 15-min GT cadence: newest held purchase -3d (90d on first run) to now, <= 30-day chunks, max 2 requests/run, skips a run while windows are in flight. A1 mig 20260911161500.';

-- ── 3. SeatGeek drain: ≤2 next-pages queued / run ─────────────────────────────
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
      tix AS (
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

      -- Page on while the window has more — but at most 2 new requests per drain run
      -- (SeatGeek token burst budget is shared); the rest page on the next run because
      -- an un-paged window stays un-advanced only in the watermark sense: its page-1
      -- row is resolved, so re-queue page+1 explicitly here on the following drain.
      IF v_total IS NOT NULL AND r.page * r.per_page < v_total AND r.page < 50 THEN
        IF v_next < 2 THEN
          PERFORM public.sg_purchases_sync(r.start_time, r.end_time, r.page + 1, r.per_page);
          v_next := v_next + 1;
        ELSE
          -- leave this row unresolved so the next drain pages it; nothing else changes
          CONTINUE;
        END IF;
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
COMMENT ON FUNCTION public.sg_purchases_drain() IS
  'Parse queued /purchases responses into seatgeek_purchases (REDACTED tickets), page on while meta.total says more (max 2 new page requests per run — shared token burst), then our_purchases_map(). A1 mig 20260911161500.';

-- ── 4. Crons: 15-min GT cadence, policy rows renamed ─────────────────────────
DELETE FROM public.cron_policy
 WHERE jobname IN ('sg_purchases_sync_30min','sg_purchases_drain_30min',
                   'gt_purchases_sync_30min','gt_purchases_drain_30min');
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, notes)
VALUES
  ('sg_purchases_sync_15min',
   ARRAY[6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 15, 30, NULL, 80,
   'Poll our SeatGeek buy-side book (brokerdata /purchases) on the GT 15-min cadence; <=2 windows/run. mig 20260911161500'),
  ('sg_purchases_drain_15min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 5, 5,
   'SELECT EXISTS (SELECT 1 FROM public.sg_purchases_pending WHERE resolved_at IS NULL)', 96,
   'Drain queued /purchases responses; <=2 next pages/run; maps to tevo. mig 20260911161500'),
  ('gt_purchases_sync_15min',
   ARRAY[6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 15, 30, NULL, 80,
   'Poll our GoTickets buy-side book (/rest/purchases) beside the GT sales pull; <=2 chunks/run. mig 20260911161500'),
  ('gt_purchases_drain_15min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 5, 5,
   'SELECT EXISTS (SELECT 1 FROM public.gt_purchases_pending WHERE resolved_at IS NULL)', 96,
   'Drain queued /rest/purchases responses; maps to tevo. mig 20260911161500')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min = excluded.peak_min_interval_min,
  offpeak_min_interval_min = excluded.offpeak_min_interval_min,
  daily_max_fires = excluded.daily_max_fires,
  work_check_sql = excluded.work_check_sql, notes = excluded.notes, updated_at = now();

DO $cron$
DECLARE j text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  FOREACH j IN ARRAY ARRAY['sg_purchases_sync_30min','sg_purchases_drain_30min',
                           'gt_purchases_sync_30min','gt_purchases_drain_30min',
                           'sg_purchases_sync_15min','sg_purchases_drain_15min',
                           'gt_purchases_sync_15min','gt_purchases_drain_15min'] LOOP
    PERFORM cron.unschedule(j) WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = j);
  END LOOP;
  PERFORM cron.schedule('sg_purchases_sync_15min', '4,19,34,50 * * * *', $body$
    DO $b$ BEGIN IF NOT public.cron_should_fire('sg_purchases_sync_15min') THEN RETURN; END IF;
      PERFORM public.sg_purchases_sync(); END $b$;$body$);
  PERFORM cron.schedule('gt_purchases_sync_15min', '4,19,34,50 * * * *', $body$
    DO $b$ BEGIN IF NOT public.cron_should_fire('gt_purchases_sync_15min') THEN RETURN; END IF;
      PERFORM public.gt_purchases_sync(); END $b$;$body$);
  PERFORM cron.schedule('sg_purchases_drain_15min', '9,24,39,55 * * * *', $body$
    DO $b$ BEGIN IF NOT public.cron_should_fire('sg_purchases_drain_15min') THEN RETURN; END IF;
      PERFORM public.sg_purchases_drain(); END $b$;$body$);
  PERFORM cron.schedule('gt_purchases_drain_15min', '9,24,39,55 * * * *', $body$
    DO $b$ BEGIN IF NOT public.cron_should_fire('gt_purchases_drain_15min') THEN RETURN; END IF;
      PERFORM public.gt_purchases_drain(); END $b$;$body$);
END;
$cron$;
