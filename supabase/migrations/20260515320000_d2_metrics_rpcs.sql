-- Migration 20260515320000 · lane:D2 · writes:d2_metrics_window(),d2_metrics_hourly_buckets(),d2_metrics_top_events() · reads:unified_orders · pre:20260513230100,20260514000000 · auth:operator-gated (D2 author + preview only)
-- D2 metrics aggregation RPCs feeding the Metrics tab in d2_dashboard.
-- 3 SECURITY INVOKER fns, filtered to evo/seatgeek/seatdata/tickpick/vivid.
-- Rationale + design notes: docs/release-discipline.md (token-discipline §1).

-- ============================================================================
-- 1. d2_metrics_window — KPI rollup per source for one time window
-- ============================================================================

CREATE OR REPLACE FUNCTION public.d2_metrics_window(
  p_start timestamptz,
  p_end   timestamptz
)
RETURNS TABLE (
  source           text,
  orders_count     bigint,
  fulfilled_count  bigint,
  gross_total      numeric,
  fulfilled_gross  numeric,
  qty_total        bigint,
  fulfilled_qty    bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    uo.source,
    count(*)::bigint                                                          AS orders_count,
    count(*) FILTER (WHERE uo.is_sale_succeeded)::bigint                      AS fulfilled_count,
    coalesce(sum(uo.gross_value), 0)::numeric                                 AS gross_total,
    coalesce(sum(uo.gross_value) FILTER (WHERE uo.is_sale_succeeded), 0)::numeric AS fulfilled_gross,
    coalesce(sum(uo.quantity), 0)::bigint                                     AS qty_total,
    coalesce(sum(uo.quantity) FILTER (WHERE uo.is_sale_succeeded), 0)::bigint AS fulfilled_qty
  FROM public.unified_orders uo
  WHERE uo.created_at >= p_start
    AND uo.created_at <  p_end
    AND uo.source IN ('evo', 'seatgeek', 'seatdata', 'tickpick', 'vivid')
  GROUP BY uo.source;
$$;

REVOKE EXECUTE ON FUNCTION public.d2_metrics_window(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_window(timestamptz, timestamptz) TO service_role;

COMMENT ON FUNCTION public.d2_metrics_window IS
  'Per-source KPI rollup for a [p_start, p_end) window over public.unified_orders. Used by the Metrics tab in d2_dashboard. fulfilled_* = filtered to is_sale_succeeded; total_* = all rows regardless of canonical_status. SECURITY INVOKER — caller must be service_role.';

-- ============================================================================
-- 2. d2_metrics_hourly_buckets — 24-bar sparkline data
-- ============================================================================

CREATE OR REPLACE FUNCTION public.d2_metrics_hourly_buckets(
  p_start timestamptz,
  p_end   timestamptz
)
RETURNS TABLE (
  hour_bucket      timestamptz,
  source           text,
  orders_count     bigint,
  gross            numeric,
  fulfilled_gross  numeric
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    date_trunc('hour', uo.created_at) AS hour_bucket,
    uo.source,
    count(*)::bigint                                                              AS orders_count,
    coalesce(sum(uo.gross_value), 0)::numeric                                     AS gross,
    coalesce(sum(uo.gross_value) FILTER (WHERE uo.is_sale_succeeded), 0)::numeric AS fulfilled_gross
  FROM public.unified_orders uo
  WHERE uo.created_at >= p_start
    AND uo.created_at <  p_end
    AND uo.source IN ('evo', 'seatgeek', 'seatdata', 'tickpick', 'vivid')
  GROUP BY 1, 2
  ORDER BY 1 ASC, 2 ASC;
$$;

REVOKE EXECUTE ON FUNCTION public.d2_metrics_hourly_buckets(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_hourly_buckets(timestamptz, timestamptz) TO service_role;

COMMENT ON FUNCTION public.d2_metrics_hourly_buckets IS
  'Hour-bucketed sales rollup for the Metrics tab sparkline. App code sums across sources to render a single 24-bar series; raw per-source rows are exposed in case the operator wants a stacked view later.';

-- ============================================================================
-- 3. d2_metrics_top_events — leaderboard of events by gross
-- ============================================================================

CREATE OR REPLACE FUNCTION public.d2_metrics_top_events(
  p_start timestamptz,
  p_end   timestamptz,
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  tevo_event_id   bigint,
  event_name      text,
  event_date      timestamptz,
  total_gross     numeric,
  total_count     bigint,
  fulfilled_count bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    uo.tevo_event_id,
    -- event_name + event_date are NOT in unified_orders' canonical column
    -- list — the bundler back-fills from v_event_base. Use max() as a
    -- deterministic per-group pick (event_name is per-event, not per-row,
    -- so max == any non-null value).
    max(uo.event_name)             AS event_name,
    max(uo.event_date)             AS event_date,
    coalesce(sum(uo.gross_value) FILTER (WHERE uo.is_sale_succeeded), 0)::numeric AS total_gross,
    count(*)::bigint                                                              AS total_count,
    count(*) FILTER (WHERE uo.is_sale_succeeded)::bigint                          AS fulfilled_count
  FROM public.unified_orders uo
  WHERE uo.created_at >= p_start
    AND uo.created_at <  p_end
    AND uo.tevo_event_id IS NOT NULL
    AND uo.source IN ('evo', 'seatgeek', 'seatdata', 'tickpick', 'vivid')
  GROUP BY uo.tevo_event_id
  HAVING coalesce(sum(uo.gross_value) FILTER (WHERE uo.is_sale_succeeded), 0) > 0
  ORDER BY total_gross DESC
  LIMIT p_limit;
$$;

REVOKE EXECUTE ON FUNCTION public.d2_metrics_top_events(timestamptz, timestamptz, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_top_events(timestamptz, timestamptz, int) TO service_role;

COMMENT ON FUNCTION public.d2_metrics_top_events IS
  'Top events by fulfilled gross over a time window. Skips NULL tevo_event_id. HAVING fulfilled_gross > 0 → "what closed".';

-- ============================================================================
-- 4. d2_metrics_hot_events — events with the most recent activity (velocity)
-- ============================================================================
-- Different from top_events: ranked by orders_count in the recent window,
-- not by closed gross over 7d. Surfaces events getting hit *right now*.

CREATE OR REPLACE FUNCTION public.d2_metrics_hot_events(
  p_start timestamptz,
  p_end   timestamptz,
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  tevo_event_id   bigint,
  event_name      text,
  event_date      timestamptz,
  recent_count    bigint,
  recent_gross    numeric,
  fulfilled_count bigint,
  last_order_at   timestamptz
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT
    uo.tevo_event_id,
    max(uo.event_name) AS event_name,
    max(uo.event_date) AS event_date,
    count(*)::bigint AS recent_count,
    coalesce(sum(uo.gross_value), 0)::numeric AS recent_gross,
    count(*) FILTER (WHERE uo.is_sale_succeeded)::bigint AS fulfilled_count,
    max(uo.created_at) AS last_order_at
  FROM public.unified_orders uo
  WHERE uo.created_at >= p_start
    AND uo.created_at <  p_end
    AND uo.tevo_event_id IS NOT NULL
    AND uo.source IN ('evo', 'seatgeek', 'seatdata', 'tickpick', 'vivid')
  GROUP BY uo.tevo_event_id
  ORDER BY recent_count DESC, recent_gross DESC
  LIMIT p_limit;
$$;

REVOKE EXECUTE ON FUNCTION public.d2_metrics_hot_events(timestamptz, timestamptz, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_hot_events(timestamptz, timestamptz, int) TO service_role;

COMMENT ON FUNCTION public.d2_metrics_hot_events IS
  'Events getting hit in [p_start,p_end) ranked by orders_count (velocity).';

-- ============================================================================
-- 5. d2_metrics_biggest_sales — top-$ sales since a "last run" timestamp
-- ============================================================================
-- App passes its own "last poll" timestamp; defaults to last 5 min if NULL.
-- Filtered to fulfilled (is_sale_succeeded) — biggest closed sales, not
-- biggest pending orders (which may never clear).

CREATE OR REPLACE FUNCTION public.d2_metrics_biggest_sales(
  p_since timestamptz DEFAULT NULL,
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  source           text,
  source_order_id  text,
  tevo_event_id    bigint,
  event_name       text,
  event_date       timestamptz,
  gross_value      numeric,
  quantity         bigint,
  canonical_status text,
  created_at       timestamptz
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT
    uo.source,
    uo.source_order_id,
    uo.tevo_event_id,
    uo.event_name,
    uo.event_date,
    uo.gross_value,
    uo.quantity::bigint,
    uo.canonical_status,
    uo.created_at
  FROM public.unified_orders uo
  WHERE uo.is_sale_succeeded
    AND uo.created_at >= coalesce(p_since, now() - interval '5 minutes')
    AND uo.source IN ('evo', 'seatgeek', 'seatdata', 'tickpick', 'vivid')
  ORDER BY uo.gross_value DESC NULLS LAST
  LIMIT p_limit;
$$;

REVOKE EXECUTE ON FUNCTION public.d2_metrics_biggest_sales(timestamptz, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_biggest_sales(timestamptz, int) TO service_role;

COMMENT ON FUNCTION public.d2_metrics_biggest_sales IS
  'Biggest fulfilled sales since p_since (defaults to now()-5min). Used for the "biggest since last run" surface on the Metrics tab.';

-- ============================================================================
-- 6. d2_metrics_sales_gaps — quiet stretches in fulfilled-sale activity
-- ============================================================================
-- Operator wants to know if there was sales downtime. Returns ordered
-- consecutive-row gaps > p_min_gap_minutes in the last p_lookback_hours
-- of fulfilled sales activity, per-source.

CREATE OR REPLACE FUNCTION public.d2_metrics_sales_gaps(
  p_lookback_hours  int DEFAULT 24,
  p_min_gap_minutes int DEFAULT 30
)
RETURNS TABLE (
  source         text,
  gap_start      timestamptz,
  gap_end        timestamptz,
  gap_minutes    numeric
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  WITH recent_sales AS (
    SELECT
      uo.source,
      uo.created_at,
      lag(uo.created_at) OVER (PARTITION BY uo.source ORDER BY uo.created_at) AS prev_at
    FROM public.unified_orders uo
    WHERE uo.is_sale_succeeded
      AND uo.created_at >= now() - make_interval(hours => p_lookback_hours)
      AND uo.source IN ('evo', 'seatgeek', 'seatdata', 'tickpick', 'vivid')
  )
  SELECT
    source,
    prev_at AS gap_start,
    created_at AS gap_end,
    round(extract(epoch FROM (created_at - prev_at)) / 60.0, 1) AS gap_minutes
  FROM recent_sales
  WHERE prev_at IS NOT NULL
    AND extract(epoch FROM (created_at - prev_at)) / 60.0 >= p_min_gap_minutes
  ORDER BY gap_minutes DESC
  LIMIT 50;
$$;

REVOKE EXECUTE ON FUNCTION public.d2_metrics_sales_gaps(int, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_sales_gaps(int, int) TO service_role;

COMMENT ON FUNCTION public.d2_metrics_sales_gaps IS
  'Per-source gaps in fulfilled-sale activity > p_min_gap_minutes within the last p_lookback_hours. Used for downtime detection on the Metrics tab.';
