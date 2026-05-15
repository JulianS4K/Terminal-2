-- Migration 20260515330000 · admin · Audit/Push · adds _health_check_pg_net_errors() · pre:20260515320000
--
-- Cluster A drift infra: pg_net error rate as a 60-min rolling silent-success detector.
-- Closes the visibility gap that left bot_chat 130 undetected for 4+ hours.
-- Stand-alone; integrate into release_health_check via one-line append in a follow-up:
--   RETURN QUERY SELECT * FROM public._health_check_pg_net_errors();
-- Threshold tuned to today's incident data: 74% error rate (1924/2588 in 90min) → fail.

CREATE OR REPLACE FUNCTION public._health_check_pg_net_errors()
RETURNS TABLE(check_class text, check_name text, status text, metric numeric, detail text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
  WITH last_60 AS (
    SELECT
      count(*) FILTER (WHERE status_code BETWEEN 200 AND 299 AND NOT timed_out)        AS ok,
      count(*) FILTER (WHERE status_code >= 400 OR timed_out OR status_code IS NULL)   AS err,
      count(*)                                                                          AS total
    FROM net._http_response
    WHERE created > now() - interval '60 minutes'
  )
  SELECT
    'pg_net'::text,
    'error_rate_60min'::text,
    CASE
      WHEN total = 0                       THEN 'ok'    -- no traffic, no signal
      WHEN (err::numeric / total) > 0.5    THEN 'fail'
      WHEN (err::numeric / total) > 0.2    THEN 'warn'
      ELSE 'ok'
    END,
    round(coalesce(err::numeric / nullif(total, 0), 0) * 100, 1),
    format('%s err / %s total (%s%% — fail >50%%, warn >20%%)',
           err, total,
           round(coalesce(err::numeric / nullif(total, 0), 0) * 100, 1))
  FROM last_60;
$$;

REVOKE ALL ON FUNCTION public._health_check_pg_net_errors() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._health_check_pg_net_errors() TO service_role;

COMMENT ON FUNCTION public._health_check_pg_net_errors() IS
  'Cluster A drift infra. Returns one row matching release_health_check() shape with pg_net error rate over last 60 min. Fail >50%, warn >20%. Integrate into release_health_check via RETURN QUERY append.';
