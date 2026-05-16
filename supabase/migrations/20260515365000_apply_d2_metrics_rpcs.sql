-- Migration 20260515365000 · admin · apply D2 metrics RPCs to prod · pre:20260515320000 (file)
-- D2 authored 20260515320000_d2_metrics_rpcs.sql but the file was never applied to prod
-- (D2 confirmed: 0 of 6 d2_metrics_* functions present, Metrics tab returning empty panels).
-- This is a passthrough apply — content identical to 20260515320000_d2_metrics_rpcs.sql.
-- Filename uses 365000 to avoid the structural-drift filename-collision class C1 flagged.

CREATE OR REPLACE FUNCTION public.d2_metrics_window(p_start timestamptz, p_end timestamptz)
RETURNS TABLE (source text, orders_count bigint, fulfilled_count bigint, gross_total numeric, fulfilled_gross numeric, qty_total bigint, fulfilled_qty bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT uo.source, count(*)::bigint, count(*) FILTER (WHERE uo.is_sale_succeeded)::bigint,
    coalesce(sum(uo.gross_value),0)::numeric,
    coalesce(sum(uo.gross_value) FILTER (WHERE uo.is_sale_succeeded),0)::numeric,
    coalesce(sum(uo.quantity),0)::bigint,
    coalesce(sum(uo.quantity) FILTER (WHERE uo.is_sale_succeeded),0)::bigint
  FROM public.unified_orders uo
  WHERE uo.created_at >= p_start AND uo.created_at < p_end
    AND uo.source IN ('evo','seatgeek','seatdata','tickpick','vivid')
  GROUP BY uo.source;
$$;
REVOKE EXECUTE ON FUNCTION public.d2_metrics_window(timestamptz,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_window(timestamptz,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.d2_metrics_hourly_buckets(p_start timestamptz, p_end timestamptz)
RETURNS TABLE (hour_bucket timestamptz, source text, orders_count bigint, gross numeric, fulfilled_gross numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT date_trunc('hour', uo.created_at), uo.source, count(*)::bigint,
    coalesce(sum(uo.gross_value),0)::numeric,
    coalesce(sum(uo.gross_value) FILTER (WHERE uo.is_sale_succeeded),0)::numeric
  FROM public.unified_orders uo
  WHERE uo.created_at >= p_start AND uo.created_at < p_end
    AND uo.source IN ('evo','seatgeek','seatdata','tickpick','vivid')
  GROUP BY 1,2 ORDER BY 1,2;
$$;
REVOKE EXECUTE ON FUNCTION public.d2_metrics_hourly_buckets(timestamptz,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_hourly_buckets(timestamptz,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.d2_metrics_top_events(p_start timestamptz, p_end timestamptz, p_limit int DEFAULT 10)
RETURNS TABLE (tevo_event_id bigint, event_name text, event_date timestamptz, total_gross numeric, total_count bigint, fulfilled_count bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT uo.tevo_event_id, max(uo.event_name), max(uo.event_date),
    coalesce(sum(uo.gross_value) FILTER (WHERE uo.is_sale_succeeded),0)::numeric,
    count(*)::bigint, count(*) FILTER (WHERE uo.is_sale_succeeded)::bigint
  FROM public.unified_orders uo
  WHERE uo.created_at >= p_start AND uo.created_at < p_end
    AND uo.tevo_event_id IS NOT NULL
    AND uo.source IN ('evo','seatgeek','seatdata','tickpick','vivid')
  GROUP BY uo.tevo_event_id
  HAVING coalesce(sum(uo.gross_value) FILTER (WHERE uo.is_sale_succeeded),0) > 0
  ORDER BY 4 DESC LIMIT p_limit;
$$;
REVOKE EXECUTE ON FUNCTION public.d2_metrics_top_events(timestamptz,timestamptz,int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_top_events(timestamptz,timestamptz,int) TO service_role;

CREATE OR REPLACE FUNCTION public.d2_metrics_hot_events(p_start timestamptz, p_end timestamptz, p_limit int DEFAULT 10)
RETURNS TABLE (tevo_event_id bigint, event_name text, event_date timestamptz, recent_count bigint, recent_gross numeric, fulfilled_count bigint, last_order_at timestamptz)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT uo.tevo_event_id, max(uo.event_name), max(uo.event_date),
    count(*)::bigint, coalesce(sum(uo.gross_value),0)::numeric,
    count(*) FILTER (WHERE uo.is_sale_succeeded)::bigint, max(uo.created_at)
  FROM public.unified_orders uo
  WHERE uo.created_at >= p_start AND uo.created_at < p_end
    AND uo.tevo_event_id IS NOT NULL
    AND uo.source IN ('evo','seatgeek','seatdata','tickpick','vivid')
  GROUP BY uo.tevo_event_id ORDER BY 4 DESC, 5 DESC LIMIT p_limit;
$$;
REVOKE EXECUTE ON FUNCTION public.d2_metrics_hot_events(timestamptz,timestamptz,int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_hot_events(timestamptz,timestamptz,int) TO service_role;

CREATE OR REPLACE FUNCTION public.d2_metrics_biggest_sales(p_since timestamptz DEFAULT NULL, p_limit int DEFAULT 10)
RETURNS TABLE (source text, source_order_id text, tevo_event_id bigint, event_name text, event_date timestamptz, gross_value numeric, quantity bigint, canonical_status text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  SELECT uo.source, uo.source_order_id, uo.tevo_event_id, uo.event_name, uo.event_date,
    uo.gross_value, uo.quantity::bigint, uo.canonical_status, uo.created_at
  FROM public.unified_orders uo
  WHERE uo.is_sale_succeeded
    AND uo.created_at >= coalesce(p_since, now() - interval '5 minutes')
    AND uo.source IN ('evo','seatgeek','seatdata','tickpick','vivid')
  ORDER BY uo.gross_value DESC NULLS LAST LIMIT p_limit;
$$;
REVOKE EXECUTE ON FUNCTION public.d2_metrics_biggest_sales(timestamptz,int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_biggest_sales(timestamptz,int) TO service_role;

CREATE OR REPLACE FUNCTION public.d2_metrics_sales_gaps(p_lookback_hours int DEFAULT 24, p_min_gap_minutes int DEFAULT 30)
RETURNS TABLE (source text, gap_start timestamptz, gap_end timestamptz, gap_minutes numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public
AS $$
  WITH recent_sales AS (
    SELECT uo.source, uo.created_at,
      lag(uo.created_at) OVER (PARTITION BY uo.source ORDER BY uo.created_at) AS prev_at
    FROM public.unified_orders uo
    WHERE uo.is_sale_succeeded
      AND uo.created_at >= now() - make_interval(hours => p_lookback_hours)
      AND uo.source IN ('evo','seatgeek','seatdata','tickpick','vivid')
  )
  SELECT source, prev_at, created_at,
    round(extract(epoch FROM (created_at - prev_at)) / 60.0, 1)
  FROM recent_sales WHERE prev_at IS NOT NULL
    AND extract(epoch FROM (created_at - prev_at)) / 60.0 >= p_min_gap_minutes
  ORDER BY 4 DESC LIMIT 50;
$$;
REVOKE EXECUTE ON FUNCTION public.d2_metrics_sales_gaps(int,int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.d2_metrics_sales_gaps(int,int) TO service_role;
