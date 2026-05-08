-- 20260508090000_filter_ghost_events_from_dashboards.sql
-- Code-owned (broker terminal lane).
--
-- Ghost events: future-dated rows in `events` whose latest event_metrics
-- snap is older than the longest legitimate polling interval. Cause: TEvo
-- stopped returning the event from /v9/events (series resolved, match
-- cancelled, event re-keyed) but our `events` row persists. The ghosts
-- pad league grids and Movers with stale prices.
--
-- Concrete case caught in the Knicks deep-dive (2026-05-08):
-- 8 Boston-Celtics events (R2 G5/G7, R3 G1-4, Finals G1-4 home games at TD
-- Garden) had last_snap = 2026-05-03. Knicks won R1 against Boston, TEvo
-- stopped returning Boston's R2+ contingent inventory, but our rows linger.
-- League grid was showing "Boston Celtics · 10 home events" with 5-day-stale
-- prices.
--
-- Fix: add a freshness floor (48h) to get_event_movers and
-- get_performers_by_league. Anything not snapped in 48h drops out.
--
-- Threshold rationale: collect-listings tiers run at every 20m / hourly /
-- every 4h / every 12h / daily. Worst-case legitimate gap between snaps is
-- 24h (60d+ tier). 48h doubles that for safety. Anything older = ghost.

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
    l.event_id::bigint, e.name,
    e.primary_performer_id::bigint, e.primary_performer_name,
    e.venue_id::bigint, e.venue_name,
    e.occurs_at_local::text,
    l.captured_at, p.captured_at,
    l.retail_median, p.retail_median,
    l.owned_median_retail, p.owned_median_retail,
    l.tickets_count, p.tickets_count,
    l.owned_tickets_count, p.owned_tickets_count
  FROM latest l
  JOIN events e ON e.id = l.event_id
  LEFT JOIN prior p USING (event_id)
  WHERE e.occurs_at_local::timestamptz >= now()
    AND l.captured_at > now() - interval '72 hours'  -- ghost filter (3x window already enforces this)
  ORDER BY l.captured_at DESC;
$$;

GRANT EXECUTE ON FUNCTION get_event_movers(int) TO anon, authenticated, service_role;

DROP FUNCTION IF EXISTS get_performers_by_league(text);

CREATE OR REPLACE FUNCTION get_performers_by_league(p_league text)
RETURNS TABLE (
  performer_id      bigint,
  performer_name    text,
  league            text,
  home_venue_id     bigint,
  home_venue_name   text,
  home_events       integer,
  home_market_med   numeric,
  home_owned_med    numeric,
  home_market_tix   bigint,
  home_owned_tix    bigint,
  home_first_event  text,
  home_last_event   text,
  home_prev_market_med numeric,
  home_prev_owned_med  numeric,
  road_events       integer,
  road_market_med   numeric,
  road_owned_med    numeric,
  road_market_tix   bigint,
  road_owned_tix    bigint,
  road_first_event  text,
  road_last_event   text,
  road_prev_market_med numeric,
  road_prev_owned_med  numeric
) LANGUAGE sql STABLE AS $$
  WITH latest_metrics AS (
    SELECT DISTINCT ON (event_id)
      event_id,
      retail_median, owned_median_retail,
      GREATEST(coalesce(tickets_count,0) - coalesce(ancillary_tickets,0), 0) AS tickets_count,
      owned_tickets_count, captured_at
    FROM event_metrics
    WHERE captured_at > now() - interval '48 hours'  -- ghost threshold
    ORDER BY event_id, captured_at DESC
  ),
  prev_metrics AS (
    SELECT DISTINCT ON (event_id)
      event_id, retail_median AS prev_retail_median,
      owned_median_retail AS prev_owned_med
    FROM event_metrics
    WHERE captured_at < now() - interval '24 hours'
      AND captured_at > now() - interval '96 hours'
    ORDER BY event_id, captured_at DESC
  ),
  events_in_window AS (
    SELECT e.id, e.primary_performer_id, e.performer_ids,
           e.venue_id, e.occurs_at_local,
           m.retail_median, m.owned_median_retail,
           m.tickets_count, m.owned_tickets_count,
           pm.prev_retail_median, pm.prev_owned_med
    FROM events e
    INNER JOIN latest_metrics m ON m.event_id = e.id
    LEFT JOIN prev_metrics pm ON pm.event_id = e.id
    WHERE e.occurs_at_local::timestamptz >= now()
  ),
  performer_event_pairs AS (
    SELECT
      phv.performer_id, phv.performer_name, phv.league,
      phv.venue_id AS home_venue_id, phv.venue_name AS home_venue_name,
      e.id AS event_id, e.occurs_at_local,
      (e.venue_id = phv.venue_id) AS is_home,
      e.retail_median, e.owned_median_retail,
      e.tickets_count, e.owned_tickets_count,
      e.prev_retail_median, e.prev_owned_med
    FROM performer_home_venues phv
    LEFT JOIN events_in_window e
      ON (e.primary_performer_id = phv.performer_id
          OR phv.performer_id = ANY(coalesce(e.performer_ids, ARRAY[]::integer[])))
    WHERE phv.league = p_league
      AND phv.performer_name !~* '^(NBA|MLB|NHL|MLS|NFL|WNBA|World Cup) (Playoffs|Finals|Conference|Eastern|Western|Semifinals|Quarterfinals|Wild Card|Round)'
      AND phv.performer_name !~* '(All[- ]?Star( Game)?|Summer League|Pro Bowl|Stanley Cup|Super Bowl|World Series|All Stars)'
  )
  SELECT
    performer_id, performer_name, league, home_venue_id, home_venue_name,
    (count(event_id) FILTER (WHERE is_home))::int AS home_events,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median)         FILTER (WHERE is_home AND retail_median       IS NOT NULL) AS home_market_med,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY owned_median_retail)   FILTER (WHERE is_home AND owned_median_retail IS NOT NULL) AS home_owned_med,
    (sum(tickets_count) FILTER (WHERE is_home))::bigint AS home_market_tix,
    (sum(owned_tickets_count) FILTER (WHERE is_home))::bigint AS home_owned_tix,
    min(occurs_at_local) FILTER (WHERE is_home) AS home_first_event,
    max(occurs_at_local) FILTER (WHERE is_home) AS home_last_event,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY prev_retail_median)    FILTER (WHERE is_home AND prev_retail_median IS NOT NULL)  AS home_prev_market_med,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY prev_owned_med)        FILTER (WHERE is_home AND prev_owned_med      IS NOT NULL) AS home_prev_owned_med,
    (count(event_id) FILTER (WHERE NOT is_home))::int AS road_events,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median)         FILTER (WHERE NOT is_home AND retail_median       IS NOT NULL) AS road_market_med,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY owned_median_retail)   FILTER (WHERE NOT is_home AND owned_median_retail IS NOT NULL) AS road_owned_med,
    (sum(tickets_count) FILTER (WHERE NOT is_home))::bigint AS road_market_tix,
    (sum(owned_tickets_count) FILTER (WHERE NOT is_home))::bigint AS road_owned_tix,
    min(occurs_at_local) FILTER (WHERE NOT is_home) AS road_first_event,
    max(occurs_at_local) FILTER (WHERE NOT is_home) AS road_last_event,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY prev_retail_median)    FILTER (WHERE NOT is_home AND prev_retail_median IS NOT NULL)  AS road_prev_market_med,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY prev_owned_med)        FILTER (WHERE NOT is_home AND prev_owned_med      IS NOT NULL) AS road_prev_owned_med
  FROM performer_event_pairs
  GROUP BY performer_id, performer_name, league, home_venue_id, home_venue_name
  ORDER BY (count(event_id) FILTER (WHERE is_home) + count(event_id) FILTER (WHERE NOT is_home)) DESC,
           performer_name;
$$;

GRANT EXECUTE ON FUNCTION get_performers_by_league(text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION get_event_movers IS
  'v3: 72h ghost filter on latest snap so series-resolved/cancelled events drop out of Movers.';
COMMENT ON FUNCTION get_performers_by_league IS
  'v4.1: 48h ghost filter so series-resolved events drop out of league grid (e.g. Boston-Knicks R2 contingents after R1 resolved).';
