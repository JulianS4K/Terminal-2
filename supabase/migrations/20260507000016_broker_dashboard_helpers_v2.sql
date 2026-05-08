-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-07 21:53 UTC.
-- NOTE: this is broker-lane work — flagged for review. broker_performer_dashboard
-- and broker_event_intel feed the broker terminal UI which is code's lane.

CREATE OR REPLACE FUNCTION broker_performer_dashboard(p_performer_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  WITH team_ctx AS (
    SELECT get_team_context(p_performer_id) AS ctx
  ),
  ticket_metrics AS (
    SELECT
      count(*)::int AS upcoming_events,
      sum(em.tickets_count)::int AS total_listed_tickets,
      sum(em.owned_tickets_count)::int AS s4k_owned_tickets,
      avg(em.retail_median)::numeric(12,2) AS avg_event_median_price,
      sum(em.retail_sum)::numeric(14,2) AS gross_listed_value
    FROM events e
    LEFT JOIN latest_event_metrics em ON em.event_id = e.id
    WHERE e.primary_performer_id = p_performer_id
      AND e.occurs_at_local::date >= current_date
  ),
  upcoming AS (
    SELECT jsonb_agg(jsonb_build_object(
      'event_id', e.id, 'name', e.name, 'occurs_at_local', e.occurs_at_local,
      'venue', e.venue_name,
      'is_home', (hv.venue_id IS NOT NULL AND e.venue_id = hv.venue_id),
      'tickets_listed', em.tickets_count,
      'tickets_s4k_owned', em.owned_tickets_count,
      'price_from', em.retail_min, 'price_median', em.retail_median, 'price_to', em.retail_max,
      'getin_price', em.getin_price,
      'series_stage', classify_playoff_stage(e.name),
      'game_number', extract_game_number(e.name)) ORDER BY e.occurs_at_local ASC) AS items
    FROM events e
    LEFT JOIN latest_event_metrics em ON em.event_id = e.id
    LEFT JOIN performer_home_venues hv ON hv.performer_id = e.primary_performer_id
    WHERE e.primary_performer_id = p_performer_id
      AND e.occurs_at_local::date >= current_date
    LIMIT 20
  )
  SELECT jsonb_build_object(
    'sport_context', (SELECT ctx FROM team_ctx),
    'ticket_summary', (SELECT to_jsonb(t) FROM ticket_metrics t),
    'upcoming_events', (SELECT items FROM upcoming)
  );
$fn$;

CREATE OR REPLACE VIEW broker_event_intel AS
WITH home_perf AS (
  SELECT e.id AS event_id, e.name, e.occurs_at_local, e.venue_id, e.venue_name,
         e.primary_performer_id AS home_performer_id,
         e.primary_performer_name AS home_team_name
  FROM events e
  WHERE e.occurs_at_local::date >= current_date
    AND e.primary_performer_id IS NOT NULL
)
SELECT
  hp.event_id,
  hp.name AS event_name,
  hp.occurs_at_local,
  hp.venue_name,
  hp.home_performer_id,
  hp.home_team_name,
  extract_opponent(hp.name, hp.home_team_name) AS opponent_name,
  (SELECT performer_id FROM performer_home_venues
   WHERE lower(performer_name) = lower(extract_opponent(hp.name, hp.home_team_name))
   LIMIT 1) AS opponent_performer_id,
  classify_playoff_stage(hp.name) AS series_stage,
  extract_game_number(hp.name) AS game_number,
  em.tickets_count AS tickets_listed,
  em.owned_tickets_count AS tickets_s4k_owned,
  em.retail_min AS price_from,
  em.retail_median AS price_median,
  em.retail_max AS price_to,
  em.getin_price,
  ts.record_summary AS home_team_record,
  ts.streak AS home_team_streak,
  ts.playoff_seed AS home_team_seed,
  COALESCE((
    SELECT max(intensity) FROM wiki_rivalries r
    WHERE (r.performer_a_id = hp.home_performer_id
           AND r.performer_b_id = (SELECT performer_id FROM performer_home_venues
                                   WHERE lower(performer_name) = lower(extract_opponent(hp.name, hp.home_team_name)) LIMIT 1))
       OR (r.performer_b_id = hp.home_performer_id
           AND r.performer_a_id = (SELECT performer_id FROM performer_home_venues
                                   WHERE lower(performer_name) = lower(extract_opponent(hp.name, hp.home_team_name)) LIMIT 1))
  ), 0) AS rivalry_intensity,
  (
    SELECT max(rivalry_name) FROM wiki_rivalries r
    WHERE (r.performer_a_id = hp.home_performer_id
           AND r.performer_b_id = (SELECT performer_id FROM performer_home_venues
                                   WHERE lower(performer_name) = lower(extract_opponent(hp.name, hp.home_team_name)) LIMIT 1))
       OR (r.performer_b_id = hp.home_performer_id
           AND r.performer_a_id = (SELECT performer_id FROM performer_home_venues
                                   WHERE lower(performer_name) = lower(extract_opponent(hp.name, hp.home_team_name)) LIMIT 1))
  ) AS rivalry_name
FROM home_perf hp
LEFT JOIN latest_event_metrics em ON em.event_id = hp.event_id
LEFT JOIN team_xref tx ON tx.tevo_performer_id = hp.home_performer_id
LEFT JOIN LATERAL (
  SELECT * FROM espn_team_snapshots WHERE espn_team_id = tx.espn_team_id
  ORDER BY captured_at DESC LIMIT 1
) ts ON true;

CREATE OR REPLACE FUNCTION broker_recent_intel(p_days_back int DEFAULT 7, p_days_ahead int DEFAULT 14)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'recent_trades', get_recent_team_changes(now() - (p_days_back || ' days')::interval, 50),
    'marquee_upcoming', (
      SELECT jsonb_agg(jsonb_build_object(
        'event_id', event_id, 'event_name', event_name,
        'occurs_at_local', occurs_at_local, 'venue', venue_name,
        'matchup', home_team_name || ' vs ' || COALESCE(opponent_name, '?'),
        'rivalry_name', rivalry_name, 'rivalry_intensity', rivalry_intensity,
        'series_stage', series_stage, 'game_number', game_number,
        'tickets_s4k_owned', tickets_s4k_owned,
        'price_from', price_from, 'price_median', price_median,
        'home_team_record', home_team_record) ORDER BY rivalry_intensity DESC NULLS LAST, occurs_at_local ASC)
      FROM broker_event_intel
      WHERE occurs_at_local::date <= current_date + p_days_ahead
        AND (rivalry_intensity >= 6 OR series_stage IS NOT NULL)
      LIMIT 30
    ),
    'recent_news', (
      SELECT jsonb_agg(jsonb_build_object(
        'headline', n.headline, 'team_id', n.espn_team_id, 'league', n.espn_league,
        'published_at', n.published_at, 'url', n.url) ORDER BY n.published_at DESC)
      FROM (SELECT * FROM espn_news ORDER BY published_at DESC NULLS LAST LIMIT 30) n
    ),
    'open_injuries', (
      SELECT count(*)::int FROM espn_injuries_snapshots
      WHERE captured_at >= now() - (p_days_back || ' days')::interval
    )
  );
$fn$;
