-- Migration 20260514180000 · level:admin · lane:Audit/Push · writes:139 views (security_invoker option flip) · reads:- · pre:20260514155818
-- Security advisor ERROR sweep — Level 1 of the post-pause cleanup.
--
-- Before: 139 ERROR security_definer_view lints. Modern Supabase advisor
--         flags any view that runs with the creator's permissions (postgres
--         superuser) instead of the caller's — i.e. bypasses RLS. In
--         Postgres 15+ the default flipped from DEFINER → INVOKER but
--         pre-existing views still carry the old behavior.
-- After:  0 ERROR. Verified via get_advisors immediately post-apply.
-- Total advisor count: 486 → 347.
--
-- Why now: crons paused 2026-05-14 17:15 UTC (bot_chat row 106) — DDL window
-- safe. Idempotent (SET option same-value is a no-op). Reversible:
--   ALTER VIEW <name> RESET (security_invoker);
--
-- Operator directive: "kanban all the issues on a board, deal with them one
-- by one level by level" — this is Level 1 (ERROR class).
--
-- Already applied to prod via MCP at 2026-05-14 ~17:32 UTC. This PR is the
-- idempotent codification per SYNC_PROTOCOL §5. Re-apply is a no-op.

ALTER VIEW public.broker_event_metrics SET (security_invoker = true);
ALTER VIEW public.broker_event_sections SET (security_invoker = true);
ALTER VIEW public.broker_event_zones SET (security_invoker = true);
ALTER VIEW public.broker_listings SET (security_invoker = true);
ALTER VIEW public.chat_audit_lies SET (security_invoker = true);
ALTER VIEW public.chat_audit_recurring_lies SET (security_invoker = true);
ALTER VIEW public.chat_corpus_training SET (security_invoker = true);
ALTER VIEW public.chat_failures SET (security_invoker = true);
ALTER VIEW public.chat_glossary_candidates SET (security_invoker = true);
ALTER VIEW public.cross_source_coverage SET (security_invoker = true);
ALTER VIEW public.cross_source_event_audit SET (security_invoker = true);
ALTER VIEW public.data_source_field_map_audit SET (security_invoker = true);
ALTER VIEW public.entity_event_map SET (security_invoker = true);
ALTER VIEW public.entity_performer_map SET (security_invoker = true);
ALTER VIEW public.entity_venue_map SET (security_invoker = true);
ALTER VIEW public.espn_event_snapshot_latest SET (security_invoker = true);
ALTER VIEW public.espn_injury_snapshot_latest SET (security_invoker = true);
ALTER VIEW public.espn_team_snapshot_latest SET (security_invoker = true);
ALTER VIEW public.event_lifecycle SET (security_invoker = true);
ALTER VIEW public.event_series SET (security_invoker = true);
ALTER VIEW public.event_velocity SET (security_invoker = true);
ALTER VIEW public.events_with_home_flag SET (security_invoker = true);
ALTER VIEW public.evo_orders_by_event SET (security_invoker = true);
ALTER VIEW public.latest_snapshots SET (security_invoker = true);
ALTER VIEW public.latest_zone_metrics SET (security_invoker = true);
ALTER VIEW public.matchup_history SET (security_invoker = true);
ALTER VIEW public.order_status_coverage SET (security_invoker = true);
ALTER VIEW public.our_orders SET (security_invoker = true);
ALTER VIEW public.our_orders_by_event SET (security_invoker = true);
ALTER VIEW public.our_orders_by_event_with_net SET (security_invoker = true);
ALTER VIEW public.our_orders_with_net SET (security_invoker = true);
ALTER VIEW public.retail_event_metrics SET (security_invoker = true);
ALTER VIEW public.retail_event_sections SET (security_invoker = true);
ALTER VIEW public.retail_event_zones SET (security_invoker = true);
ALTER VIEW public.retail_events SET (security_invoker = true);
ALTER VIEW public.retail_listings SET (security_invoker = true);
ALTER VIEW public.sd_sales_normalized SET (security_invoker = true);
ALTER VIEW public.seatdata_event_latest SET (security_invoker = true);
ALTER VIEW public.seatgeek_categorized_listings SET (security_invoker = true);
ALTER VIEW public.seatgeek_event_latest SET (security_invoker = true);
ALTER VIEW public.seatgeek_orders_by_event SET (security_invoker = true);
ALTER VIEW public.sg_canonical_match_view SET (security_invoker = true);
ALTER VIEW public.team_xref SET (security_invoker = true);
ALTER VIEW public.unified_listings SET (security_invoker = true);
ALTER VIEW public.unified_orders SET (security_invoker = true);
ALTER VIEW public.unified_orders_by_event SET (security_invoker = true);
ALTER VIEW public.v_arbitrage_opportunities SET (security_invoker = true);
ALTER VIEW public.v_broadway_runs SET (security_invoker = true);
ALTER VIEW public.v_broker_configurations SET (security_invoker = true);
ALTER VIEW public.v_canonical_coverage SET (security_invoker = true);
ALTER VIEW public.v_canonical_coverage_v2 SET (security_invoker = true);
ALTER VIEW public.v_canonical_drift SET (security_invoker = true);
ALTER VIEW public.v_canonical_event SET (security_invoker = true);
ALTER VIEW public.v_canonical_performer SET (security_invoker = true);
ALTER VIEW public.v_canonical_venue SET (security_invoker = true);
ALTER VIEW public.v_competing_events SET (security_invoker = true);
ALTER VIEW public.v_cron_health SET (security_invoker = true);
ALTER VIEW public.v_dashboard_coverage SET (security_invoker = true);
ALTER VIEW public.v_dashboard_freshness SET (security_invoker = true);
ALTER VIEW public.v_espn_game_results SET (security_invoker = true);
ALTER VIEW public.v_espn_injuries_current SET (security_invoker = true);
ALTER VIEW public.v_espn_team_state SET (security_invoker = true);
ALTER VIEW public.v_event_active_weather_alerts SET (security_invoker = true);
ALTER VIEW public.v_event_base SET (security_invoker = true);
ALTER VIEW public.v_event_betting_odds_latest SET (security_invoker = true);
ALTER VIEW public.v_event_calendar_context SET (security_invoker = true);
ALTER VIEW public.v_event_competing_events SET (security_invoker = true);
ALTER VIEW public.v_event_competitors SET (security_invoker = true);
ALTER VIEW public.v_event_data_freshness SET (security_invoker = true);
ALTER VIEW public.v_event_espn_injuries SET (security_invoker = true);
ALTER VIEW public.v_event_espn_news SET (security_invoker = true);
ALTER VIEW public.v_event_espn_state SET (security_invoker = true);
ALTER VIEW public.v_event_evo_orders SET (security_invoker = true);
ALTER VIEW public.v_event_full SET (security_invoker = true);
ALTER VIEW public.v_event_full_sports SET (security_invoker = true);
ALTER VIEW public.v_event_full_v2 SET (security_invoker = true);
ALTER VIEW public.v_event_holidays SET (security_invoker = true);
ALTER VIEW public.v_event_home_away SET (security_invoker = true);
ALTER VIEW public.v_event_injuries SET (security_invoker = true);
ALTER VIEW public.v_event_line_movement SET (security_invoker = true);
ALTER VIEW public.v_event_major_calendar SET (security_invoker = true);
ALTER VIEW public.v_event_mlb_branded_series SET (security_invoker = true);
ALTER VIEW public.v_event_nws_alerts SET (security_invoker = true);
ALTER VIEW public.v_event_overlay_summary SET (security_invoker = true);
ALTER VIEW public.v_event_reddit SET (security_invoker = true);
ALTER VIEW public.v_event_sales_combined SET (security_invoker = true);
ALTER VIEW public.v_event_school_breaks SET (security_invoker = true);
ALTER VIEW public.v_event_seating_chart SET (security_invoker = true);
ALTER VIEW public.v_event_sporting_rivalries SET (security_invoker = true);
ALTER VIEW public.v_event_team_standings SET (security_invoker = true);
ALTER VIEW public.v_event_tournament_context SET (security_invoker = true);
ALTER VIEW public.v_event_velocity_windows SET (security_invoker = true);
ALTER VIEW public.v_event_weather SET (security_invoker = true);
ALTER VIEW public.v_event_weather_with_fallback SET (security_invoker = true);
ALTER VIEW public.v_event_why_context SET (security_invoker = true);
ALTER VIEW public.v_event_xref_collisions SET (security_invoker = true);
ALTER VIEW public.v_event_xref_proposed SET (security_invoker = true);
ALTER VIEW public.v_events_5w SET (security_invoker = true);
ALTER VIEW public.v_events_pullable SET (security_invoker = true);
ALTER VIEW public.v_listing_zone_auto SET (security_invoker = true);
ALTER VIEW public.v_macro_indicators_health SET (security_invoker = true);
ALTER VIEW public.v_macro_indicators_latest SET (security_invoker = true);
ALTER VIEW public.v_mlb_game_series SET (security_invoker = true);
ALTER VIEW public.v_one_to_one_health SET (security_invoker = true);
ALTER VIEW public.v_open_alerts SET (security_invoker = true);
ALTER VIEW public.v_orphan_seatdata_data SET (security_invoker = true);
ALTER VIEW public.v_orphan_seatgeek_data SET (security_invoker = true);
ALTER VIEW public.v_outgoing_terms_without_incoming_alias SET (security_invoker = true);
ALTER VIEW public.v_performer_news_sources SET (security_invoker = true);
ALTER VIEW public.v_performer_reddit_pulse SET (security_invoker = true);
ALTER VIEW public.v_performer_residencies SET (security_invoker = true);
ALTER VIEW public.v_performer_tours SET (security_invoker = true);
ALTER VIEW public.v_pg_net_queue_health SET (security_invoker = true);
ALTER VIEW public.v_pricing_cross_source SET (security_invoker = true);
ALTER VIEW public.v_reddit_important_recent SET (security_invoker = true);
ALTER VIEW public.v_rivalry_events SET (security_invoker = true);
ALTER VIEW public.v_s4k_inventoried_events SET (security_invoker = true);
ALTER VIEW public.v_seatgeek_listings_classified SET (security_invoker = true);
ALTER VIEW public.v_section_to_curated_zone SET (security_invoker = true);
ALTER VIEW public.v_sg_event_match_proposals SET (security_invoker = true);
ALTER VIEW public.v_sg_events_by_status SET (security_invoker = true);
ALTER VIEW public.v_sg_events_ignored_historic SET (security_invoker = true);
ALTER VIEW public.v_sg_events_pending_match SET (security_invoker = true);
ALTER VIEW public.v_sg_historic_concert_performer SET (security_invoker = true);
ALTER VIEW public.v_sg_historic_per_matchup SET (security_invoker = true);
ALTER VIEW public.v_sg_historic_per_performer SET (security_invoker = true);
ALTER VIEW public.v_sg_historic_per_section_kind SET (security_invoker = true);
ALTER VIEW public.v_sg_sales_by_event SET (security_invoker = true);
ALTER VIEW public.v_sg_sales_by_section SET (security_invoker = true);
ALTER VIEW public.v_sg_unmatched_candidate_performers SET (security_invoker = true);
ALTER VIEW public.v_subreddits_unified SET (security_invoker = true);
ALTER VIEW public.v_team_at_venue_history SET (security_invoker = true);
ALTER VIEW public.v_team_last_n_at_venue SET (security_invoker = true);
ALTER VIEW public.v_unmapped_incoming_tokens SET (security_invoker = true);
ALTER VIEW public.v_unmatched_events SET (security_invoker = true);
ALTER VIEW public.v_upcoming_rivalry_games SET (security_invoker = true);
ALTER VIEW public.v_venue_climatology SET (security_invoker = true);
ALTER VIEW public.v_venue_neighbors SET (security_invoker = true);
ALTER VIEW public.v_x_accounts_unified SET (security_invoker = true);
