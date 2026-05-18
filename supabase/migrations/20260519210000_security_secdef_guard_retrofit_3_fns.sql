-- 20260519210000_security_secdef_guard_retrofit_3_fns.sql
--
-- §6 SECDEF body-guard retrofit on 3 cron-internal functions.
-- Closes KANBAN.md B1-NEXT-8, B1-NEXT-29, B1-NEXT-30.
--
-- WHY:
--   All 3 functions ship as SECURITY DEFINER with `SET search_path` already set,
--   but lack the §6 (BOT_HIERARCHY.md) in-body caller guard:
--     IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN RAISE;
--
--   None of the 3 has a legitimate non-cron caller. All cron firings run as
--   service_role and pass the guard. Verified 2026-05-18:
--     - _health_check_pg_net_errors:        no fn/cron callers (orphan check fn);
--                                           release_health_check inlines its own checks.
--     - refresh_sg_broker_sales_event_metrics: called only by `sg_broker_sales_metrics_refresh_hourly` (:17 cron, service_role).
--     - sg_seller_orders_queue:             called only by `sg_seller_orders_queue_30min` (:2,:32 cron, service_role).
--
-- WHAT:
--   1. Convert _health_check_pg_net_errors from LANGUAGE sql -> plpgsql so the
--      guard can RAISE. Body wrapped as RETURN QUERY against the unchanged
--      SELECT — return shape preserved.
--   2. Prepend the §6 guard to the other 2 functions verbatim.
--   3. REVOKE EXECUTE FROM PUBLIC + anon + authenticated for all 3 (cron-internal;
--      no PostgREST consumer should reach them). GRANT to service_role.
--      sg_seller_orders_queue currently has public_exec=TRUE — the real
--      defense-in-depth bug B1-NEXT-30 flagged.
--
-- INVARIANTS PRESERVED:
--   - All 3 signatures unchanged (no overload creation per PROJECT_BIBLE §7
--     "function signature changes" landmine).
--   - search_path config unchanged.
--   - Return types unchanged.
--   - Volatility (STABLE for #1, default VOLATILE for #2/#3) unchanged.
--
-- ROLLBACK:
--   Re-apply the prior pg_get_functiondef() output for each — captured in this
--   migration's git diff via the CREATE OR REPLACE delta.

-- ============================================================
-- 1/3 — _health_check_pg_net_errors()
-- ============================================================
-- Convert sql -> plpgsql to support RAISE. Wrap original SELECT in RETURN QUERY.

CREATE OR REPLACE FUNCTION public._health_check_pg_net_errors()
RETURNS TABLE(check_class text, check_name text, status text, metric numeric, detail text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION '_health_check_pg_net_errors: caller % not authorized', current_user;
  END IF;

  RETURN QUERY
  WITH last_60 AS (
    SELECT
      count(*) FILTER (WHERE status_code BETWEEN 200 AND 299 AND NOT timed_out) AS ok,
      count(*) FILTER (WHERE status_code >= 400 OR timed_out OR status_code IS NULL) AS err,
      count(*) AS total
    FROM net._http_response
    WHERE created > now() - interval '60 minutes'
  )
  SELECT
    'pg_net'::text,
    'error_rate_60min'::text,
    CASE
      WHEN total = 0                    THEN 'ok'
      WHEN (err::numeric / total) > 0.5 THEN 'fail'
      WHEN (err::numeric / total) > 0.2 THEN 'warn'
      ELSE 'ok'
    END,
    round(coalesce(err::numeric / nullif(total, 0), 0) * 100, 1),
    format('%s err / %s total (%s%% — fail >50%%, warn >20%%)',
           err, total, round(coalesce(err::numeric / nullif(total, 0), 0) * 100, 1))
  FROM last_60;
END
$function$;

REVOKE EXECUTE ON FUNCTION public._health_check_pg_net_errors() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._health_check_pg_net_errors() FROM anon;
REVOKE EXECUTE ON FUNCTION public._health_check_pg_net_errors() FROM authenticated;
GRANT  EXECUTE ON FUNCTION public._health_check_pg_net_errors() TO service_role;


-- ============================================================
-- 2/3 — refresh_sg_broker_sales_event_metrics(integer)
-- ============================================================

CREATE OR REPLACE FUNCTION public.refresh_sg_broker_sales_event_metrics(p_max_events integer DEFAULT 200)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := now();
  v_count int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'refresh_sg_broker_sales_event_metrics: caller % not authorized', current_user;
  END IF;

  WITH deduped AS (
    SELECT DISTINCT ON (sg_sale_id)
      sg_event_id, tevo_event_id, sg_sale_id, broadcast_price, sale_at_utc
    FROM public.seatgeek_sales_snapshots
    WHERE sale_at_utc > v_now - interval '24 hours'
    ORDER BY sg_sale_id, pulled_at DESC
  ),
  agg AS (
    SELECT
      d.sg_event_id,
      coalesce(
        max(d.tevo_event_id),
        (SELECT tevo_event_id FROM public.seatgeek_event_xref WHERE sg_event_id = d.sg_event_id LIMIT 1)
      ) AS tevo_event_id,
      count(DISTINCT d.sg_sale_id) AS sold_quantity,
      round(sum(d.broadcast_price)::numeric, 2) AS sold_gross,
      min(d.broadcast_price) AS sold_price_min,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY d.broadcast_price)::numeric AS sold_price_median,
      round(avg(d.broadcast_price)::numeric, 2) AS sold_price_mean,
      max(d.broadcast_price) AS sold_price_max
    FROM deduped d
    GROUP BY d.sg_event_id
    HAVING count(DISTINCT d.sg_sale_id) > 0
    LIMIT p_max_events
  )
  INSERT INTO public.seatgeek_event_metrics (
    sg_event_id, tevo_event_id, captured_at,
    sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_mean, sold_price_max
  )
  SELECT sg_event_id, tevo_event_id, v_now,
         sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_mean, sold_price_max
  FROM agg
  WHERE tevo_event_id IS NOT NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END
$function$;

REVOKE EXECUTE ON FUNCTION public.refresh_sg_broker_sales_event_metrics(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_sg_broker_sales_event_metrics(integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.refresh_sg_broker_sales_event_metrics(integer) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_sg_broker_sales_event_metrics(integer) TO service_role;


-- ============================================================
-- 3/3 — sg_seller_orders_queue(integer, text)
-- ============================================================
-- Pre-state: public_exec=TRUE (real defense-in-depth bug per B1-NEXT-30).

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
    SELECT net.http_get(
      url := 'https://sellerdirect-api.seatgeek.com/orders?per_page=200&status='
             || trim(v_status) || '&token=' || v_token,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO sg_seller_pending(request_id, scope, page, per_page, status_csv)
    VALUES (v_req_id, 'orders', 1, 200, trim(v_status));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END
$function$;

REVOKE EXECUTE ON FUNCTION public.sg_seller_orders_queue(integer, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.sg_seller_orders_queue(integer, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.sg_seller_orders_queue(integer, text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_seller_orders_queue(integer, text) TO service_role;


-- ============================================================
-- Post-apply verification (operator runs after apply_migration)
-- ============================================================
-- expected: all 3 rows show has_caller_guard=true, public_exec=false, anon_exec=false, authed_exec=false, service_role_exec=true
--
-- WITH fns AS (
--   SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args,
--          pg_get_functiondef(p.oid) AS def
--   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--   WHERE n.nspname='public'
--     AND p.proname IN ('_health_check_pg_net_errors','refresh_sg_broker_sales_event_metrics','sg_seller_orders_queue')
-- )
-- SELECT proname, args,
--        (def ILIKE '%current_user%' AND def ILIKE '%RAISE%') AS has_caller_guard,
--        has_function_privilege('public', oid, 'EXECUTE')        AS public_exec,
--        has_function_privilege('anon', oid, 'EXECUTE')          AS anon_exec,
--        has_function_privilege('authenticated', oid, 'EXECUTE') AS authed_exec,
--        has_function_privilege('service_role', oid, 'EXECUTE')  AS service_role_exec
-- FROM fns ORDER BY proname;
