-- 20260508050000_performers_by_league_rpc.sql
-- Code-owned (broker terminal lane).
--
-- Per-team HOME/ROAD price metrics for ESPN-tracked teams in a league.
-- Backs the league-browse strip in the Performers tab + the
-- /api/broker/performers/by-league/{league} endpoint.
--
-- For each team in performer_home_venues with the requested league:
--   HOME = future events at the team's home venue where the performer is
--          primary_performer_id or appears in performer_ids[]
--   ROAD = future events elsewhere where the performer appears in
--          primary_performer_id or performer_ids[]
--
-- Aggregates: event count, median of latest event-level retail medians,
-- summed tickets (market + owned), first/last event date.

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
  road_events       integer,
  road_market_med   numeric,
  road_owned_med    numeric,
  road_market_tix   bigint,
  road_owned_tix    bigint,
  road_first_event  text,
  road_last_event   text
) LANGUAGE sql STABLE AS $$
  WITH latest_metrics AS (
    SELECT DISTINCT ON (event_id)
      event_id, retail_median, owned_median_retail,
      tickets_count, owned_tickets_count
    FROM event_metrics
    WHERE captured_at > now() - interval '24 hours'
    ORDER BY event_id, captured_at DESC
  ),
  events_in_window AS (
    SELECT e.id, e.primary_performer_id, e.performer_ids,
           e.venue_id, e.occurs_at_local,
           m.retail_median, m.owned_median_retail,
           m.tickets_count, m.owned_tickets_count
    FROM events e
    LEFT JOIN latest_metrics m ON m.event_id = e.id
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
      e.venue_id     AS event_venue_id,
      e.occurs_at_local,
      (e.venue_id = phv.venue_id) AS is_home,
      e.retail_median, e.owned_median_retail,
      e.tickets_count, e.owned_tickets_count
    FROM performer_home_venues phv
    LEFT JOIN events_in_window e
      ON (e.primary_performer_id = phv.performer_id
          OR phv.performer_id = ANY(coalesce(e.performer_ids, ARRAY[]::integer[])))
    WHERE phv.league = p_league
  )
  SELECT
    performer_id,
    performer_name,
    league,
    home_venue_id,
    home_venue_name,
    (count(event_id) FILTER (WHERE is_home))::int                                                                          AS home_events,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median)         FILTER (WHERE is_home AND retail_median IS NOT NULL)        AS home_market_med,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY owned_median_retail)   FILTER (WHERE is_home AND owned_median_retail IS NOT NULL)  AS home_owned_med,
    (sum(tickets_count) FILTER (WHERE is_home))::bigint                                                                    AS home_market_tix,
    (sum(owned_tickets_count) FILTER (WHERE is_home))::bigint                                                              AS home_owned_tix,
    min(occurs_at_local) FILTER (WHERE is_home)                                                                            AS home_first_event,
    max(occurs_at_local) FILTER (WHERE is_home)                                                                            AS home_last_event,
    (count(event_id) FILTER (WHERE NOT is_home))::int                                                                      AS road_events,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_median)         FILTER (WHERE NOT is_home AND retail_median IS NOT NULL)        AS road_market_med,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY owned_median_retail)   FILTER (WHERE NOT is_home AND owned_median_retail IS NOT NULL)  AS road_owned_med,
    (sum(tickets_count) FILTER (WHERE NOT is_home))::bigint                                                                AS road_market_tix,
    (sum(owned_tickets_count) FILTER (WHERE NOT is_home))::bigint                                                          AS road_owned_tix,
    min(occurs_at_local) FILTER (WHERE NOT is_home)                                                                        AS road_first_event,
    max(occurs_at_local) FILTER (WHERE NOT is_home)                                                                        AS road_last_event
  FROM performer_event_pairs
  GROUP BY performer_id, performer_name, league, home_venue_id, home_venue_name
  ORDER BY (count(event_id) FILTER (WHERE is_home) + count(event_id) FILTER (WHERE NOT is_home)) DESC,
           performer_name;
$$;

GRANT EXECUTE ON FUNCTION get_performers_by_league(text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION get_performers_by_league IS
  'Per-league HOME/ROAD price metrics for ESPN-tracked teams. Backs /api/broker/performers/by-league.';
