-- Migration 20260911080000 · level:data-collection · lane:D7 · writes:sg_seller_pending · reads:net._http_response,sg_seller_pending · pre:20260515370000
-- ============================================================================
-- Migration 20260911080000 — SeatGeek SellerDirect orders: fetch the TAIL pages
-- (authored as 20260911050000; renumbered 2026-09-11 after D4 landed a migration
--  with that prefix on main — PR #975)
--
-- Lane:     D7 (operator-directed; the function is A1's order ingest — flagged)
-- Touches:  sg_seller_orders_queue(integer, text) — body replace, same signature,
--           same SECURITY DEFINER guard. sg_seller_process() unchanged (a tail
--           page is an 'orders' page like any other).
-- Pre-reqs: 20260515370000 (per-status page-1 pull), 20260510030000 (contract)
--
-- READ-ONLY upstream: GET /orders only, two more pages per status. RULE 2 holds.
--
-- Operator 2026-09-11: "you have vivid too — and SeatGeek check". The N2S
-- mapper (20260911040000, rule 0e) can take a SeatGeek obligation's event from
-- our own SellerDirect order pull — but that pull never reaches a current
-- order. Measured 2026-09-11 03:13 UTC, straight from the responses:
--
--   status     rows we hold   newest created   upstream total   page fetched
--   confirmed        200        2020-02-19         6,633           1 of 34
--   fulfilled        200        2025-06-02       582,238           1 of 2,912
--   open / pending / delivered  0                    0             —
--
-- The API returns page 1 ASCENDING by creation, so every 30 minutes we re-pull
-- the same 200 orders from 2019 and upsert them in place (last_status_at moves,
-- nothing else). Sixteen live SeatGeek N2S orders: 0 of 16 in the table.
--
-- ── THE FIX ────────────────────────────────────────────────────────────────
-- Keep the page-1 fetch exactly as it is (it is also how we learn the total),
-- and for each status ALSO fetch the last page and the one before it, using
-- the total from the most recent resolved page-1 response of that status
-- (sg_seller_pending -> net._http_response -> meta.total). Two tail pages
-- cover the newest ~400 orders per status; at ~5-10 confirmed orders a day
-- that is weeks of headroom between cycles. If no page-1 response is on hand
-- (first cycle after apply, or pg_net has swept it) only page 1 fires, i.e.
-- today's behaviour — never a failure.
--
-- ⚠ THE `page=` PARAMETER IS AN EXPERIMENT THE FIRST CYCLE SETTLES. SeatGeek's
-- 2026-05 contract change deprecated offset paging on /listings ("use
-- page_cursor", 20260510030000) and this queue dropped `page=` for /orders at
-- the same time, untested. /orders still echoes meta.page/per_page/total
-- today, which is why this is worth one cycle. If a tail page comes back
-- non-200, sg_seller_process already marks it rows_persisted=-1 and moves on:
-- nothing else changes and page 1 keeps flowing. Verify after the first
-- :09/:39 cycle with
--   SELECT status_csv, page, rows_persisted FROM sg_seller_pending
--    WHERE scope='orders' AND page > 1 ORDER BY fired_at DESC LIMIT 10;
-- rows_persisted > 0 on page > 1 = current orders are landing; -1 = the API
-- refused offset paging and phase 2 (a page_cursor walk of `confirmed`, 34
-- pages once, then incremental) is the road — revert this body then.
--
-- Cost: at most +2 GETs per status per 30 min (5 statuses -> +10/30 min).
-- Idempotent: CREATE OR REPLACE; a re-run installs the same body.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sg_seller_orders_queue(p_pages integer DEFAULT 1, p_statuses text DEFAULT NULL::text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  v_req_id bigint;
  v_status text;
  v_count int := 0;
  v_total int;
  v_last int;
  v_page int;
  v_statuses text[] := coalesce(
    string_to_array(p_statuses, ','),
    ARRAY['open','pending','confirmed','fulfilled']
  );
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_seller_orders_queue: caller % not authorized', current_user;
  END IF;

  PERFORM p_pages;
  FOREACH v_status IN ARRAY v_statuses LOOP
    v_status := trim(v_status);

    -- Page 1, exactly as before (20260515370000).
    SELECT net.http_get(
      url := 'https://sellerdirect-api.seatgeek.com/orders?per_page=200&status='
             || v_status || '&token=' || v_token,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO sg_seller_pending(request_id, scope, page, per_page, status_csv)
    VALUES (v_req_id, 'orders', 1, 200, v_status);
    v_count := v_count + 1;

    -- Tail pages (20260911080000): the newest orders live on the LAST page.
    -- Total comes from the latest resolved page-1 response for this status.
    SELECT NULLIF(h.content::jsonb->'meta'->>'total', '')::int INTO v_total
      FROM sg_seller_pending p
      JOIN net._http_response h ON h.id = p.request_id
     WHERE p.scope = 'orders' AND p.status_csv = v_status AND p.page = 1
       AND p.resolved_at IS NOT NULL AND h.status_code = 200
     ORDER BY p.fired_at DESC
     LIMIT 1;

    IF v_total IS NOT NULL AND v_total > 200 THEN
      v_last := ceil(v_total / 200.0)::int;
      FOR v_page IN REVERSE v_last .. greatest(2, v_last - 1) LOOP
        SELECT net.http_get(
          url := 'https://sellerdirect-api.seatgeek.com/orders?page=' || v_page
                 || '&per_page=200&status=' || v_status || '&token=' || v_token,
          timeout_milliseconds := 30000
        ) INTO v_req_id;
        INSERT INTO sg_seller_pending(request_id, scope, page, per_page, status_csv)
        VALUES (v_req_id, 'orders', v_page, 200, v_status);
        v_count := v_count + 1;
      END LOOP;
    END IF;
  END LOOP;
  RETURN v_count;
END
$function$;

REVOKE ALL ON FUNCTION public.sg_seller_orders_queue(integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sg_seller_orders_queue(integer, text) TO service_role;

COMMENT ON FUNCTION public.sg_seller_orders_queue(integer, text) IS
  'Queue SellerDirect GET /orders pulls per status (RULE 2: GET only). Page 1 as before, plus — since 20260911080000 — the last two pages of each status, sized from the previous cycle''s meta.total, because the API pages ASCENDING by creation and page 1 alone re-pulled the same 2019 orders every cycle (0 of 16 live N2S SeatGeek orders were ever in seatgeek_orders). Drained by sg_seller_process(); tevo ids arrive via backfill_order_tevo_from_aq (hourly :40); read by n2s_map_events rule 0e.';
