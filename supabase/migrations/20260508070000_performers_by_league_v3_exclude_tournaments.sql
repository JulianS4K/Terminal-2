-- 20260508070000_performers_by_league_v3_exclude_tournaments.sql
-- Code-owned (broker terminal lane).
--
-- v3 changes:
--   1. Tournament-placeholder filter: NBA Playoffs, NBA Finals, NHL Stanley
--      Cup Finals, Super Bowl, MLB All Star Game, NBA Summer League, etc.
--      are TEvo bracket-aggregator performers, not real teams. They were
--      polluting the league grid with rows like "NBA Playoffs · 152 road
--      events" that double-count every team's playoff slate.
--   2. Ticket counts net of parking/suites/hospitality: subtract
--      ancillary_tickets from tickets_count when summing per-team totals so
--      the "9,456 tix" Knicks row doesn't include 1,000 parking spots.

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
      owned_tickets_count
    FROM event_metrics
    WHERE captured_at > now() - interval '6 hours'
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
    LEFT JOIN latest_metrics m  ON m.event_id  = e.id
    LEFT JOIN prev_metrics  pm ON pm.event_id = e.id
    WHERE e.occurs_at_local::timestamptz >= now()
  ),
  performer_event_pairs AS (
    SELECT
      phv.performer_id,
      phv.performer_name,
      phv.league,
      phv.venue_id   AS home_venue_id,
      phv.venue_name AS home_venue_name,
      e.id           AS event_id,
      e.occurs_at_local,
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

COMMENT ON FUNCTION get_performers_by_league IS
  'v3: per-league HOME/ROAD price metrics, excludes tournament placeholders, ticket counts net of parking/ancillary.';
