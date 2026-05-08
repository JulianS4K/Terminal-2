-- 20260508040000_broker_movers_rpc.sql
-- Code-owned (broker terminal lane).
--
-- Backs /api/broker/movers. Pre-aggregates latest + prior event_metrics
-- snapshot per event_id in SQL so the FastAPI endpoint doesn't have to pull
-- thousands of rows through PostgREST (which has a default per-request row
-- cap of 1000 — that was silently truncating the dataset and producing an
-- empty Movers report even when the underlying data was rich).
--
-- Returns one row per event with current + prior values for the four
-- metrics the Movers page tracks: market median, owned median, market tix,
-- owned tix. Future-dated only.

CREATE OR REPLACE FUNCTION get_event_movers(p_window_hours int DEFAULT 24)
RETURNS TABLE (
  event_id              bigint,
  name                  text,
  primary_performer_id  bigint,
  primary_performer_name text,
  venue_id              bigint,
  venue_name            text,
  occurs_at_local       text,
  latest_at             timestamptz,
  prior_at              timestamptz,
  cur_market_med        numeric,
  prev_market_med       numeric,
  cur_owned_med         numeric,
  prev_owned_med        numeric,
  cur_market_tix        integer,
  prev_market_tix       integer,
  cur_owned_tix         integer,
  prev_owned_tix        integer
) LANGUAGE sql STABLE AS $$
  WITH window_rows AS (
    -- Pull a 3x window so we always have a prior snap to compare against.
    SELECT m.event_id, m.captured_at,
           m.retail_median, m.owned_median_retail,
           m.tickets_count, m.owned_tickets_count
    FROM event_metrics m
    WHERE m.captured_at > now() - (p_window_hours * 3 || ' hours')::interval
  ),
  latest AS (
    SELECT DISTINCT ON (event_id)
      event_id, captured_at,
      retail_median, owned_median_retail,
      tickets_count, owned_tickets_count
    FROM window_rows
    ORDER BY event_id, captured_at DESC
  ),
  prior AS (
    SELECT DISTINCT ON (event_id)
      event_id, captured_at,
      retail_median, owned_median_retail,
      tickets_count, owned_tickets_count
    FROM window_rows
    WHERE captured_at < now() - (p_window_hours || ' hours')::interval
    ORDER BY event_id, captured_at DESC
  )
  SELECT
    l.event_id::bigint,
    e.name,
    e.primary_performer_id::bigint,
    e.primary_performer_name,
    e.venue_id::bigint,
    e.venue_name,
    e.occurs_at_local::text,
    l.captured_at AS latest_at,
    p.captured_at AS prior_at,
    l.retail_median        AS cur_market_med,
    p.retail_median        AS prev_market_med,
    l.owned_median_retail  AS cur_owned_med,
    p.owned_median_retail  AS prev_owned_med,
    l.tickets_count        AS cur_market_tix,
    p.tickets_count        AS prev_market_tix,
    l.owned_tickets_count  AS cur_owned_tix,
    p.owned_tickets_count  AS prev_owned_tix
  FROM latest l
  JOIN events e ON e.id = l.event_id
  LEFT JOIN prior p USING (event_id)
  WHERE e.occurs_at_local::timestamptz >= now()
  ORDER BY l.captured_at DESC;
$$;

GRANT EXECUTE ON FUNCTION get_event_movers(int) TO anon, authenticated, service_role;

COMMENT ON FUNCTION get_event_movers IS
  'Per-event latest + prior snap aggregation for the Movers report. Window: comparison spans p_window_hours (1..168). Backs /api/broker/movers — replaces the prior approach of pulling all rows via PostgREST (which capped at 1000 rows) and doing the aggregation in Python.';
