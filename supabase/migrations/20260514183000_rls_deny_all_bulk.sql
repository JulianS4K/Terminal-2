-- Migration 20260514183000 · level:admin · lane:Audit/Push · writes:121 RLS policies (deny-all explicit) · reads:- · pre:20260514182000
-- Security advisor INFO sweep — Level 3 of the post-pause cleanup.
--
-- Before: 121 INFO rls_enabled_no_policy lints. Tables have RLS turned on
--         but no policies → deny-by-default for non-service_role. Functionally
--         secure (service_role bypasses RLS) but advisor flags as unconfigured.
-- After:  0 INFO of this class. Cumulative 486 → 5 advisor lints (−99%).
--
-- Strategy: write an EXPLICIT deny-all policy on each. No behavioral change
-- (service_role still bypasses RLS), but the policy's existence documents
-- intent ("this table is admin-only by design") and satisfies the advisor.
--
-- Tables that need anon-readable access already have explicit GRANT SELECT
-- plus their own policies (or are accessed via SECURITY INVOKER views /
-- public RPC fetchers like get_*_assets_public flipped in Level 2b).
-- None of the 121 below need anon read; all are internal queues, pulls,
-- xrefs, snapshots, sales tables, coordination tables, or admin reference.
--
-- Policy shape: FOR ALL TO anon, authenticated, coworker_readonly USING (false).
-- service_role and postgres bypass RLS by default and remain unaffected.
-- Idempotent: DO block checks pg_policies first before CREATE.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 ~17:55 UTC during cron-paused window
-- (bot_chat row 106). Idempotent codification per SYNC_PROTOCOL §5.

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'bot_chat','bot_messages','bot_users','canonical_external_ids',
    'chat_aliases','chat_audit_findings','chat_corpus','chat_glossary_known',
    'chat_rate_limits','chat_stopwords','chat_term_freq_in','chat_term_freq_out',
    'chat_term_frequency','data_source_field_map','data_sources',
    'espn_asset_crawl_state','espn_athlete_team_history','espn_event_date_lookup',
    'espn_injuries_snapshots','espn_news','espn_runs','espn_scoreboard_pending',
    'espn_team_snapshots','espn_tournament_events','espn_tournament_pending',
    'event_alerts','event_competitors_snapshot','event_match_attempts',
    'event_metrics','event_pulls','event_sentiment','evo_event_backfill_pending',
    'evo_order_items','evo_orders','evo_orders_pending','fred_pending',
    'general_subreddits','holidays','important_x_accounts','macro_indicators',
    'macro_series_config','major_event_calendar','matchup_xref',
    'mlb_branded_series','news_keywords','nws_alert_pending','nws_alert_references',
    'nws_alert_zones','nws_alerts','order_fee_schedule','order_status_xref',
    'performer_baselines','performer_crawl_state','performer_espn_team_xref',
    'performer_external_ids','performer_home_venues','performer_metadata',
    'performer_subreddits','performer_wiki_pending','performer_wikipedia',
    'performer_zone_rules','performer_zones','pull_rate_limits','reddit_pending',
    'reddit_posts','runs','school_break_windows','seatdata_event_stats',
    'seatdata_event_xref','seatdata_listings_snapshots','seatdata_performer_xref',
    'seatdata_pull_budget','seatdata_pull_log','seatdata_sales_snapshots',
    'seatdata_section_xref','seatdata_venue_xref','seatdata_zone_xref',
    'seatgeek_event_metrics','seatgeek_event_xref','seatgeek_historic_sales',
    'seatgeek_listings_snapshots','seatgeek_order_tickets','seatgeek_orders',
    'seatgeek_performer_xref','seatgeek_pull_log','seatgeek_sales_snapshots',
    'seatgeek_seller_listings','seatgeek_seller_pull_log','seatgeek_venue_xref',
    'section_metrics','settings','sg_event_backfill_pending','sg_event_match_pending',
    'sg_events_canonical','sg_listings_pending','sg_seller_pending','share_links',
    'snapshots','sporting_rivalries','taxonomy_xref','tevo_ticket_groups_cache',
    'tickpick_orders','tickpick_orders_pending','tournament_categories',
    'tournament_category_pending','tournament_search_pending','tournament_search_queries',
    'venue_baselines','venue_crawl_state','venue_geocode_pending',
    'venue_nws_points_pending','venue_pulls','vivid_orders','vivid_orders_pending',
    'watch_sources','watchlist','weather_forecast_pending','weather_observations',
    'why_signals','zone_metrics','zone_rules'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=t
    ) THEN
      EXECUTE format(
        'CREATE POLICY admin_only ON public.%I FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false)',
        t
      );
    END IF;
  END LOOP;
END $$;

-- ============================================================================
-- Sub-level 2d: document the 2 intentional matview API exposures.
-- COMMENT-only; satisfies "advisor flagged but accepted" documentation.
-- ============================================================================

COMMENT ON MATERIALIZED VIEW public.latest_event_metrics IS
  'Per-event latest event_metrics row, refreshed every 5 min by cron latest_event_metrics_refresh_5min. INTENTIONAL API EXPOSURE: granted to anon/authenticated/service_role so /api/store/events catalog can hit it without authn. Originated PR #71 to fix the 50s catalog timeout. Advisor flag materialized_view_in_api is accepted as expected behavior.';

COMMENT ON MATERIALIZED VIEW public.v_dashboard_writes_24h IS
  'Dashboard 24h write velocity, refreshed every 15 min by cron dashboard_writes_24h_refresh_60s (was 60s pre-IO-diet PR #86). INTENTIONAL API EXPOSURE for terminal dashboard. Advisor flag materialized_view_in_api is accepted.';
