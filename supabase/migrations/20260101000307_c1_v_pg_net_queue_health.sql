-- Migration 20260512100180 · level:supervisor · lane:canonical · writes:v_pg_net_queue_health · reads:nws_alert_pending,sg_seller_pending,sg_event_backfill_pending,sg_listings_pending,espn_scoreboard_pending,espn_tournament_pending,evo_orders_pending,evo_event_backfill_pending,performer_wiki_pending,reddit_pending,weather_forecast_pending,venue_geocode_pending,venue_nws_points_pending,tournament_category_pending,tournament_search_pending · pre:-

CREATE OR REPLACE VIEW v_pg_net_queue_health AS
WITH q AS (
  SELECT 'nws_alert_pending'::text AS queue,
         COUNT(*) FILTER (WHERE resolved_at IS NULL) AS unresolved,
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours') AS stale_12h,
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours') AS stale_24h,
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL) AS oldest_unresolved
    FROM nws_alert_pending
  UNION ALL
  SELECT 'sg_seller_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM sg_seller_pending
  UNION ALL
  SELECT 'sg_event_backfill_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM sg_event_backfill_pending
  UNION ALL
  SELECT 'sg_listings_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM sg_listings_pending
  UNION ALL
  SELECT 'espn_scoreboard_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM espn_scoreboard_pending
  UNION ALL
  SELECT 'espn_tournament_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM espn_tournament_pending
  UNION ALL
  SELECT 'evo_orders_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM evo_orders_pending
  UNION ALL
  SELECT 'evo_event_backfill_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM evo_event_backfill_pending
  UNION ALL
  SELECT 'performer_wiki_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM performer_wiki_pending
  UNION ALL
  SELECT 'reddit_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM reddit_pending
  UNION ALL
  SELECT 'weather_forecast_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM weather_forecast_pending
  UNION ALL
  SELECT 'venue_geocode_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM venue_geocode_pending
  UNION ALL
  SELECT 'venue_nws_points_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM venue_nws_points_pending
  UNION ALL
  SELECT 'tournament_category_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM tournament_category_pending
  UNION ALL
  SELECT 'tournament_search_pending', COUNT(*) FILTER (WHERE resolved_at IS NULL),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours'),
         COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '24 hours'),
         MIN(fired_at) FILTER (WHERE resolved_at IS NULL)
    FROM tournament_search_pending
)
SELECT
  queue, unresolved, stale_12h, stale_24h, oldest_unresolved,
  CASE WHEN unresolved = 0 THEN 'clean'
       WHEN stale_24h > 100 THEN 'critical'
       WHEN stale_24h > 25 THEN 'warning'
       WHEN unresolved > 0 THEN 'monitoring'
  END AS status
FROM q;

COMMENT ON VIEW v_pg_net_queue_health IS
  'Aggregate health monitor across 15 pg_net *_pending tables. Status: clean (0 unresolved), monitoring (>0), warning (>25 stale_24h), critical (>100 stale_24h). Surfaces the pg_net retention class bug discovered on nws_alert_pending.';

GRANT SELECT ON v_pg_net_queue_health TO coworker_readonly;
