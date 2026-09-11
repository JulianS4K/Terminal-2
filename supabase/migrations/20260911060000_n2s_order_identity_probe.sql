-- Migration 20260911060000 · level:secondary-sales · lane:D7 · writes:n2s_order_probe,vivid_orders_pending,gt_sales_sync_state,vivid_orders,gt_sales_drain,cron.job · reads:n2s_items,vivid_orders,gotickets_sales,aq_event_map · pre:20260911040000
-- ============================================================================
-- Migration 20260911060000 — N2S: pull the order BY ID the tick it arrives
--                            (Vivid getOrder, GoTickets /rest/sales/{id}),
--                            then cross-map what comes back
--
-- Lane:     D7 · Pre-reqs: 20260911040000 (rules 0c/0d read the books this
--           fills), 20260910290000 (cron 598 shape), 20260911020000
-- Touches:  n2s_order_probe (NEW), n2s_order_identity_pull() (NEW),
--           gt_sales_drain() (anchored edit: accepts a single-sale object),
--           vivid_orders (W: tevo_event_id cross-map, N2S rows only),
--           vivid_orders_pending + gt_sales_sync_state (W: one row per probe),
--           cron 598 (prepend the probe)
--
-- READ-ONLY upstream: two GET endpoints, one request per obligation.
--   Vivid     GET brokers.vividseats.com/webservices/v1/getOrder?orderId=<id>
--   GoTickets GET sc.gotickets.com/rest/sales/<id>
-- Both already in the client catalogue (vivid_client.get_order,
-- gotickets_client.get_sale). RULE 2 holds; nothing is written upstream.
--
-- Operator 2026-09-11: "why didn't you find GoTickets with GoTickets, and SG
-- with SG?" … "do for what we have to map and crossmap".
--
-- ── WHY A SCHEDULED FEED CANNOT DO THIS ────────────────────────────────────
-- Measured 2026-09-11 (docs/d7_n2s_pipeline.md §2):
--   GoTickets  the list feed (/rest/sales) returns a sale only while it is
--              live. Every N2S GoTickets order that arrived after the feed
--              existed (7/7) is in gotickets_sales and matches on gt_sale_id
--              exactly — but a sale we fail to confirm is cancelled at GT and
--              drops out of the list; whether the 15-minute sync caught it is
--              luck. The per-sale endpoint returns it regardless (the client
--              documents cancelReason='REJECTED' on that shape).
--   Vivid      cron 207 pulls getOrders?status=PENDING_SHIPMENT only; the
--              N2S-failed orders carry another status (0/117 in the book,
--              their neighbours present). getOrder?orderId= needs no status.
-- So: when an obligation lands unmapped and its order is not in our book,
-- fetch THAT order, land it through the existing drains, and let rules
-- 0c/0d map it on the next tick. One GET per obligation, at most once per
-- six hours, three attempts. Numeric order numbers only (URL safety).
--
-- ── CROSS-MAP: from the marketplace's event id to ours ─────────────────────
--   Vivid     raw.productionId = aq_event_map.vivid_event_id -> tevo_event_id.
--             Measured on 3,935 recent orders: 2,820 hub hits, 2,619 with a
--             tevo id, 2,533 agree / 2 disagree with the slower AQ-name path
--             (backfill_order_tevo_from_aq, hourly). raw.eventId hits nothing.
--             The probe writes vivid_orders.tevo_event_id for N2S rows so the
--             row itself carries the answer; rule 0d also falls back to the
--             same hub join (20260911040000) so ordering does not matter.
--   GoTickets gt_event_id -> gotickets_event (GT mappers) else the hub
--             (aq_event_map.gotickets_event_id: 765 of 1,032 recent sale events
--             carry a tevo id there, 436 agree / 1 disagree with the catalogue,
--             328 hub-only). Rule 0c carries that fallback (20260911040000).
--
-- ── DRAINS ─────────────────────────────────────────────────────────────────
-- Responses are async (pg_net). The probe function opens each tick by
-- draining whatever has landed: vivid_orders_process() (already handles a
-- single <order> document — its xpath is //order) and gt_sales_drain(),
-- which until now required a JSON ARRAY body; the per-sale endpoint returns
-- ONE OBJECT, so the drain is patched (anchored) to wrap an object into a
-- one-element array. Everything else in both drains is untouched.
-- ============================================================================

-- ── 1. gt_sales_drain accepts a single-sale object ─────────────────────────
DO $do$
DECLARE d text; n1 text; n2 text;
BEGIN
  d := pg_get_functiondef('public.gt_sales_drain()'::regprocedure);
  IF position('jsonb_build_array(r.content::jsonb)' in d) > 0 THEN
    RAISE NOTICE 'gt_sales_drain already accepts a single-sale object — skipping';
  ELSE
    n1 := 'left(r.content, 1) = ''['' THEN';
    n2 := 'jsonb_array_elements(r.content::jsonb) AS e';
    IF (length(d) - length(replace(d, n1, ''))) / length(n1) <> 1
       OR (length(d) - length(replace(d, n2, ''))) / length(n2) <> 1 THEN
      RAISE EXCEPTION 'gt_sales_drain anchors not found exactly once — body drifted, re-derive 20260911060000';
    END IF;
    d := replace(d, n1, 'left(r.content, 1) IN (''['', ''{'') THEN');
    d := replace(d, n2, 'jsonb_array_elements(CASE WHEN left(r.content, 1) = ''{'' THEN jsonb_build_array(r.content::jsonb) ELSE r.content::jsonb END) AS e');
    EXECUTE d;
  END IF;
END $do$;

COMMENT ON FUNCTION public.gt_sales_drain() IS
  'Drain pg_net responses recorded in gt_sales_sync_state into gotickets_sales (upsert on gt_sale_id). Accepts the list shape (JSON array, /rest/sales) and — since 20260911060000 — the per-sale shape (one JSON object, /rest/sales/{id}) fired by n2s_order_identity_pull().';

-- ── 2. Probe ledger ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.n2s_order_probe (
  n2s_id        bigint PRIMARY KEY,
  s4k_source    text        NOT NULL,
  order_number  text        NOT NULL,
  request_id    bigint,
  fired_at      timestamptz NOT NULL DEFAULT now(),
  attempts      int         NOT NULL DEFAULT 1,
  found_at      timestamptz
);
COMMENT ON TABLE public.n2s_order_probe IS
  'One row per N2S obligation whose order was fetched BY ID from its marketplace (Vivid getOrder, GoTickets /rest/sales/{id}) because the scheduled feeds did not hold it (20260911060000). found_at is set once the order is in our book. Re-probed after 6h while unmapped, at most 3 attempts.';
ALTER TABLE public.n2s_order_probe ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_order_probe FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.n2s_order_probe TO service_role;

-- ── 3. The tick: drain → cross-map → fire probes ───────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_order_identity_pull(p_max integer DEFAULT 10)
RETURNS TABLE(drained_vivid integer, drained_gt integer, crossmapped_vivid integer, found integer, fired_vivid integer, fired_gt integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_dv int := 0; v_dg int := 0; v_cm int := 0; v_found int := 0; v_fv int := 0; v_fg int := 0;
  v_vivid_token text;
  v_gt_id text; v_gt_secret text;
  v_req bigint;
  r RECORD;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'n2s_order_identity_pull: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;

  -- 3a. Drain what landed since the last tick (both drains are upsert-only).
  IF EXISTS (SELECT 1 FROM public.vivid_orders_pending WHERE resolved_at IS NULL) THEN
    SELECT coalesce(sum(orders_persisted), 0)::int INTO v_dv FROM public.vivid_orders_process();
  END IF;
  IF EXISTS (SELECT 1 FROM public.gt_sales_sync_state WHERE drained_at IS NULL) THEN
    SELECT coalesce(public.gt_sales_drain(), 0) INTO v_dg;
  END IF;

  -- 3b. Cross-map Vivid rows that belong to the open N2S book: hub on productionId.
  UPDATE public.vivid_orders o
     SET tevo_event_id = h.tevo_event_id
    FROM (SELECT o2.vivid_order_id, min(a.tevo_event_id) AS tevo_event_id
            FROM public.vivid_orders o2
            JOIN public.n2s_items n ON n.order_number = o2.vivid_order_id
                                   AND n.s4k_source = 'Vivid Seats' AND NOT n.is_terminal
            JOIN public.aq_event_map a ON o2.raw->>'productionId' ~ '^[0-9]+$'
                                      AND a.vivid_event_id = (o2.raw->>'productionId')::bigint
                                      AND a.tevo_event_id IS NOT NULL
           WHERE o2.tevo_event_id IS NULL
           GROUP BY o2.vivid_order_id
          HAVING count(DISTINCT a.tevo_event_id) = 1) h
   WHERE o.vivid_order_id = h.vivid_order_id AND o.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_cm = ROW_COUNT;

  -- 3c. Mark probes whose order is now in a book.
  UPDATE public.n2s_order_probe p SET found_at = now()
   WHERE p.found_at IS NULL
     AND ((p.s4k_source = 'Vivid Seats' AND EXISTS (SELECT 1 FROM public.vivid_orders v WHERE v.vivid_order_id = p.order_number))
       OR (p.s4k_source = 'GoTickets'   AND EXISTS (SELECT 1 FROM public.gotickets_sales g WHERE g.gt_sale_id::text = p.order_number)));
  GET DIAGNOSTICS v_found = ROW_COUNT;

  -- 3d. Fire probes for open, unmapped obligations whose order we do not hold.
  v_vivid_token := get_app_secret('VIVID_API_TOKEN');
  SELECT trim(decrypted_secret) INTO v_gt_id     FROM vault.decrypted_secrets WHERE name = 'GOTICKETS_ACCESS_ID';
  SELECT trim(decrypted_secret) INTO v_gt_secret FROM vault.decrypted_secrets WHERE name = 'GOTICKETS_API_SECRET';

  FOR r IN
    SELECT n.n2s_id, n.s4k_source, n.order_number, p.attempts
      FROM public.n2s_items n
      LEFT JOIN public.n2s_order_probe p ON p.n2s_id = n.n2s_id
     WHERE n.tevo_event_id IS NULL AND NOT n.is_terminal
       AND n.event_dt::date >= current_date
       AND n.s4k_source IN ('Vivid Seats', 'GoTickets')
       AND n.order_number ~ '^[0-9]+$'
       AND (p.n2s_id IS NULL OR (p.found_at IS NULL AND p.attempts < 3 AND p.fired_at < now() - interval '6 hours'))
       AND NOT (n.s4k_source = 'Vivid Seats' AND EXISTS (SELECT 1 FROM public.vivid_orders v WHERE v.vivid_order_id = n.order_number))
       AND NOT (n.s4k_source = 'GoTickets'   AND EXISTS (SELECT 1 FROM public.gotickets_sales g WHERE g.gt_sale_id::text = n.order_number))
     ORDER BY n.alert_at DESC NULLS LAST
     LIMIT greatest(p_max, 0)
  LOOP
    v_req := NULL;
    IF r.s4k_source = 'Vivid Seats' THEN
      CONTINUE WHEN v_vivid_token IS NULL OR v_vivid_token = '';
      SELECT net.http_get(
        url := 'https://brokers.vividseats.com/webservices/v1/getOrder?apiToken=' || v_vivid_token
               || '&orderId=' || r.order_number,
        headers := '{"Accept":"application/xml"}'::jsonb,
        timeout_milliseconds := 30000) INTO v_req;
      INSERT INTO public.vivid_orders_pending(request_id, query_str) VALUES (v_req, 'orderId=' || r.order_number);
      v_fv := v_fv + 1;
    ELSE
      CONTINUE WHEN v_gt_id IS NULL OR v_gt_secret IS NULL;
      SELECT net.http_get(
        url := 'https://sc.gotickets.com/rest/sales/' || r.order_number,
        headers := jsonb_build_object('X-Api-Access-Id', v_gt_id, 'X-Api-Access-Secret', v_gt_secret, 'Accept', 'application/json'),
        timeout_milliseconds := 30000) INTO v_req;
      INSERT INTO public.gt_sales_sync_state(request_id, req_limit) VALUES (v_req, 1);
      v_fg := v_fg + 1;
    END IF;

    INSERT INTO public.n2s_order_probe (n2s_id, s4k_source, order_number, request_id, fired_at, attempts)
    VALUES (r.n2s_id, r.s4k_source, r.order_number, v_req, now(), 1)
    ON CONFLICT (n2s_id) DO UPDATE
      SET request_id = EXCLUDED.request_id, fired_at = now(), attempts = public.n2s_order_probe.attempts + 1;
  END LOOP;

  RETURN QUERY SELECT v_dv, v_dg, v_cm, v_found, v_fv, v_fg;
END $fn$;

REVOKE ALL ON FUNCTION public.n2s_order_identity_pull(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_order_identity_pull(integer) TO service_role;

COMMENT ON FUNCTION public.n2s_order_identity_pull(integer) IS
  'Per-tick (cron 598, first statement): drain pending Vivid/GoTickets responses, cross-map N2S Vivid rows via the hub on raw.productionId, then for open unmapped Vivid/GoTickets obligations whose order is NOT in our book fire one GET by order id (Vivid getOrder, GoTickets /rest/sales/{id}; RULE 2 GET-only), landing through the existing drains so rules 0c/0d map them next tick. At most p_max probes per tick, one per obligation per 6h, 3 attempts. Ledger: n2s_order_probe.';

-- ── 4. Cron 598: the probe runs first, so its drains feed this tick's mapper ─
DO $do$
DECLARE v_cmd text;
BEGIN
  SELECT command INTO v_cmd FROM cron.job WHERE jobid = 598;
  IF v_cmd IS NULL THEN
    RAISE NOTICE 'cron 598 not found — schedule n2s_order_identity_pull() by hand';
  ELSIF position('n2s_order_identity_pull' in v_cmd) > 0 THEN
    RAISE NOTICE 'cron 598 already runs n2s_order_identity_pull — skipping';
  ELSIF position('SELECT public.n2s_map_events(true);' in v_cmd) = 0 THEN
    RAISE EXCEPTION 'cron 598 command drifted (no n2s_map_events(true) anchor) — re-derive 20260911060000';
  ELSE
    PERFORM cron.alter_job(598, command := replace(v_cmd,
      'SELECT public.n2s_map_events(true);',
      'SELECT public.n2s_order_identity_pull(); SELECT public.n2s_map_events(true);'));
  END IF;
END $do$;
