-- 20260508080000_event_movers_v2_parking_net.sql
-- Code-owned (broker terminal lane).
--
-- get_event_movers v2: subtract ancillary_tickets (parking, suites,
-- hospitality boxes) from tickets_count when reporting cur/prev counts.
-- This makes the Movers $-value metric (price × tickets) compute on
-- real seat inventory only — parking spots holding 6000 cars at MSG were
-- inflating the notional value swings and skewing winner/loser ranks.

DROP FUNCTION IF EXISTS get_event_movers(int);

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
    SELECT m.event_id, m.captured_at,
           m.retail_median, m.owned_median_retail,
           GREATEST(coalesce(m.tickets_count,0) - coalesce(m.ancillary_tickets,0), 0) AS tickets_count,
           m.owned_tickets_count
    FROM event_metrics m
    WHERE m.captured_at > now() - (p_window_hours * 3 || ' hours')::interval
  ),
  latest AS (
    SELECT DISTINCT ON (event_id) * FROM window_rows
    ORDER BY event_id, captured_at DESC
  ),
  prior AS (
    SELECT DISTINCT ON (event_id) * FROM window_rows
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
  'v2: per-event latest+prior aggregation, tickets net of parking/suites/hospitality.';
