-- ============================================================================
-- Migration 20260509460000 — coworker_readonly DB role for UI handoff
--
-- Phase 2 preamble: a UI coworker is starting on the Data Quality Dashboard
-- (and will own UI from here forward). They need to:
--   - SELECT from public.* tables and views
--   - EXECUTE read-only helper functions (get_event_context etc.)
--   - Sandbox in design_test schema (CREATE/SELECT/INSERT/UPDATE/DELETE)
--
-- They MUST NOT:
--   - Write to public.*  (no INSERT/UPDATE/DELETE/TRUNCATE)
--   - Touch vault.* (secrets)
--   - Touch cron.* (scheduling)
--   - Execute functions that fire net.http_* (data-plane writers)
--
-- This migration creates the role and grants. Connection string is given
-- to the coworker out-of-band (treat the password like any other secret).
-- ============================================================================

-- (1) Create role with login + a placeholder password (rotated post-handoff)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'coworker_readonly') THEN
    CREATE ROLE coworker_readonly LOGIN PASSWORD 'CHANGE_ME_BEFORE_HANDOFF';
  END IF;
END $$;

-- (2) Read-only on public schema
GRANT USAGE ON SCHEMA public TO coworker_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO coworker_readonly;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO coworker_readonly;

-- New tables/views created later automatically pick up SELECT
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO coworker_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO coworker_readonly;

-- (3) EXECUTE on the AI/RAG-context + read helper functions.
-- Conditional grant: signatures may evolve; skip without erroring.
DO $$
DECLARE r record; safe_funcs text[] := ARRAY[
  'get_event_context','match_news_keywords','get_wiki_context',
  'get_team_context','get_team_playoff_context','get_team_roster',
  'get_player_info','haversine_miles','get_broker_event_detail',
  'get_broker_events_upcoming','get_event_listings_public',
  'get_event_zones_public','get_event_zones_rollup','get_event_movers',
  'get_events_by_performer_public','get_performer_landing_public',
  'get_performer_assets_public','get_performers_by_league',
  'get_event_assets_public','get_recent_team_changes',
  'get_chat_suggestion_chips','get_events_by_venue_public',
  'get_venue_assets_public'
];
BEGIN
  FOR r IN
    SELECT p.oid,
      n.nspname || '.' || p.proname || '(' ||
      pg_get_function_identity_arguments(p.oid) || ')' AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = ANY(safe_funcs)
  LOOP
    EXECUTE 'GRANT EXECUTE ON FUNCTION ' || r.sig || ' TO coworker_readonly';
  END LOOP;
END $$;

-- (4) Sandbox: full access to design_test for prototyping
GRANT USAGE, CREATE ON SCHEMA design_test TO coworker_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER, REFERENCES
  ON ALL TABLES IN SCHEMA design_test TO coworker_readonly;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA design_test TO coworker_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA design_test
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO coworker_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA design_test
  GRANT EXECUTE ON FUNCTIONS TO coworker_readonly;

-- (5) Hard denials — explicit revokes on dangerous surfaces
REVOKE ALL ON SCHEMA cron FROM coworker_readonly;
REVOKE ALL ON SCHEMA vault FROM coworker_readonly;
REVOKE ALL ON ALL TABLES IN SCHEMA cron FROM coworker_readonly;
REVOKE ALL ON ALL TABLES IN SCHEMA vault FROM coworker_readonly;

-- Block functions that fire net.http_* (data-plane writers) + secret access.
-- Conditional revoke for resilience to signature changes.
DO $$
DECLARE r record; danger_funcs text[] := ARRAY[
  'evo_orders_queue','evo_orders_process','evo_event_backfill_queue',
  'evo_event_backfill_process','sg_listings_queue_window','sg_listings_process',
  'sg_seller_orders_queue','sg_seller_listings_queue','sg_seller_process',
  'sg_event_backfill_queue','sg_event_backfill_process','weather_forecast_queue',
  'weather_forecast_process','queue_performer_wiki_searches',
  'process_performer_wiki_searches','process_performer_wiki_summaries',
  'reddit_queue','reddit_process','cross_source_match_tick','compute_alerts_tick',
  'refresh_event_competitors','get_app_secret','wiki_pageviews_queue',
  'wiki_pageviews_process','venue_geocode_queue','venue_geocode_process'
];
BEGIN
  FOR r IN
    SELECT p.oid,
      n.nspname || '.' || p.proname || '(' ||
      pg_get_function_identity_arguments(p.oid) || ')' AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = ANY(danger_funcs)
  LOOP
    EXECUTE 'REVOKE EXECUTE ON FUNCTION ' || r.sig || ' FROM coworker_readonly';
  END LOOP;
END $$;

COMMENT ON ROLE coworker_readonly IS
  'UI coworker role. SELECT-only on public, sandbox in design_test, blocked '
  'from cron/vault and from any function that fires net.http_*. See '
  'COWORKER_ONBOARDING.md for handoff terms.';
