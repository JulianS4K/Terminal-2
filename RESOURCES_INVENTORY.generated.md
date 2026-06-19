# RESOURCES_INVENTORY.generated.md

> **Doc version:** v1.0.0 · **GENERATED FILE — DO NOT HAND-EDIT.**
> Regenerate with `python3 scripts/gen_inventory.py` (read-only catalog queries;
> never prints secret values). This is the *objective* index of what physically
> exists in the DB so nothing gets rebuilt. Hand-written ownership, landmines,
> taxonomy, and cross-source rules stay in `RESOURCES_BIBLE.md` (which this
> complements, not replaces).

**Snapshot:** 2026-06-19T08:00:36Z · 212 tables · 178 views · 4 matviews · 536 functions · 164 crons (151 active) · 29 edge functions

**Before authoring a new table / view / RPC / cron, Ctrl-F this file first.**

---

## Functions / RPCs (536)

_The COMPLETE list — `RESOURCES_BIBLE.md` has no RPC section and `PROJECT_BIBLE §4` covers only the hot subset. This is the one place every function is enumerated._

| Function (signature) | Returns | Comment |
|---|---|---|
| `__sync_check_list_migrations()` | TABLE(version text, name text) | Sync-check helper. Service-role only. Powers bin/sync-check.sh drift detection without needing a Supabase PAT for the migration diff portion. |
| `_alert_dedupe_ok(p_rule_key text, p_event_id bigint, p_window interval)` | boolean |  |
| `_cron_invoke_edge_fn(p_url text, p_body jsonb)` | bigint | Cron helper: invokes an edge fn URL with Bearer (anon JWT) + X-Cron-Secret from vault. Replaces JWT-in-cron-body pattern. |
| `_digest_cell(p_cur numeric, p_prev numeric, p_prefix text, p_decimals integer)` | text |  |
| `_health_check_anon_exposed_relations()` | TABLE(check_class text, check_name text, status text, metric numeric, detail text) |  |
| `_health_check_pg_net_errors()` | TABLE(check_class text, check_name text, status text, metric numeric, detail text) |  |
| `_ingest_espn_scoreboard(p_sport text, p_league_path text, p_league_label text, p_lookahead_days integer)` | integer |  |
| `_persist_weather_response(p_venue_id bigint, p_body jsonb, p_is_forecast boolean)` | integer |  |
| `_sec_norm(s text)` | text |  |
| `_sec_prefix(s text)` | text |  |
| `_sec_suffix(s text)` | integer |  |
| `_wl_require_email()` | text |  |
| `alert_mail_claim_batch(p_limit integer, p_max_attempts integer, p_stuck_minutes integer)` | TABLE(id uuid, to_email text, subject text, html text, attempts integer) |  |
| `alert_mail_mark(p_id uuid, p_ok boolean, p_error text, p_max_attempts integer)` | void |  |
| `alert_operator_needs_threshold(p_operator text)` | boolean |  |
| `approve_sg_event_match(p_pending_id bigint, p_reviewed_by text)` | void |  |
| `aq_consolidate_safe_dups(p_apply boolean)` | TABLE(tevo_event_id bigint, survivor_aq text, loser_aq text, action text) | A1-OPS-22: consolidate SAFE-class aq_event_map dup clusters (no platform-id conflict). Survivor = richest platform coverage; COALESCE loser ids onto it, re-point ticketsdata_event_xref, NULL loser ids (never deletes — 8 FK-deps). EXCLUDES the conflicting/doubleheader clusters. DEFAULTS TO DRY-RUN; pass true to execute. Modeled on td_reconcile_knicks_finals_aq. |
| `aq_event_map_ingest(p_rows jsonb)` | integer |  |
| `aq_league_consistent(p_tevo bigint, p_aq_category text)` | boolean |  |
| `aq_name_consistent(p_tevo text, p_aq text)` | boolean |  |
| `aq_performer_short_id(p_name text)` | text |  |
| `aq_tevo_search_candidates(p_limit integer, p_backoff_hours integer)` | TABLE(aq_id bigint, event_name text, venue_name text, city text, state text, performer text, category text, event_date timestamp without time zone, src text, last_result text) | Next batch of unmapped non-SG hub rows for the AQ->TEvo cold-search bridge. Anti-joins aq_tevo_search_attempts and orders never-tried-first to drain the full backlog. Service-role only. |
| `aq_venue_short_id(p_name text, p_city text, p_state text)` | text |  |
| `audit_chat_message(p_bot_msg_id bigint)` | jsonb |  |
| `audit_cross_source_health()` | jsonb |  |
| `auto_ack_stale_alerts()` | jsonb | Closes transient open alerts on a TTL: info-tier 2h, tevo_getin_drop_1h 6h, tevo_inventory_low_48h on event past. Critical alerts NEVER auto-ack. |
| `auto_link_event_xref()` | TABLE(linked_count integer) |  |
| `auto_match_sg_canonical()` | TABLE(attempted integer, newly_matched integer, still_unmatched integer, needs_tevo_search integer) | Legacy v1 matcher loop. A1 2026-05-17: added parking guard in loop predicate. Newer cross_source_match_tick path (v3) is preferred but this is still called via sg_canonical_auto_match_tick → cross_source_match_tick cron. |
| `auto_match_sg_canonical_relaxed(p_min_overlap numeric, p_dry_run boolean)` | TABLE(attempted integer, unique_matches integer, overlap_matches integer, unmatched integer, remaining integer) |  |
| `auto_match_sg_canonical_v3()` | TABLE(attempted integer, newly_matched integer, parking_skipped integer, still_unmatched integer, needs_tevo_search integer) |  |
| `auto_xref_sg_performers_from_listings()` | TABLE(linked_count integer, attempted_count integer) |  |
| `auto_xref_sg_venues_from_listings()` | TABLE(linked_count integer, attempted_count integer) |  |
| `axs_apply_aq(p_axs_event_id text)` | bigint |  |
| `axs_aq_backfill(p_limit integer)` | TABLE(axs_event_id text, tevo_event_id bigint) |  |
| `axs_aq_match(p_axs_event_id text, p_date_window_hours integer, p_min_score numeric)` | TABLE(tevo_event_id bigint, aq_short_event_id text, confidence numeric, method text) |  |
| `axs_artist_url(p_performer text)` | text |  |
| `axs_build_event_url(p_event_id text, p_slug_or_title text)` | text |  |
| `axs_ingest_performer_events(p_response_id bigint)` | TABLE(primary_events integer, added_to_pull integer, requests_linked integer) |  |
| `axs_ingest_snapshot(p_response_id bigint, p_axs_event_id text)` | bigint |  |
| `axs_probe_step(p_max_attempts integer, p_refresh_hours integer, p_ingest_limit integer)` | TABLE(action text, ev text, detail text) |  |
| `axs_refresh_performers()` | integer |  |
| `axs_search_events(p_q text)` | TABLE(axs_event_id text, event_url text, source_sheets text, is_axs_primary boolean, probe_status text, venue_guess text, venue_is_axs boolean) |  |
| `axs_slugify(p_text text)` | text |  |
| `backfill_aq_maps()` | jsonb |  |
| `backfill_event_nonowned_median(p_max_events integer)` | TABLE(updated_count integer) |  |
| `backfill_event_sentiment(p_max_events integer)` | TABLE(updated_count integer) |  |
| `backfill_event_splits_metrics(p_max_events integer)` | TABLE(updated_count integer) |  |
| `backfill_matchup_xref()` | TABLE(matchups_created integer) |  |
| `backfill_order_tevo_from_aq()` | TABLE(tbl text, newly_mapped integer) |  |
| `backfill_seatgeek_event_metrics(p_max_events integer)` | TABLE(updated_count integer) |  |
| `backfill_seatgeek_orders_resolved(p_limit integer)` | TABLE(attempted integer, venue_matched integer, full_matched integer) |  |
| `backfill_seatgeek_sales_tevo_event_id(p_chunk_size integer)` | TABLE(rows_updated integer, rows_remaining integer) |  |
| `backfill_stale_zone_metrics(p_max_events integer)` | TABLE(events_recomputed integer, zones_written integer) | Out-of-band catch-up for events whose zone_metrics is stale vs their latest snapshot (detected via latest_event_metrics matview). Recomputes BOTH zone + section metrics under a 90s per-event cap. Complements the non-fatal compute_event_breakdowns: heavy events soft-fail the inline 6s RPC, this finishes them under the longer budget. Driven by cron zone-backfill-isolated-10min. |
| `bot_chat_log(p_level text, p_lane text, p_event_type text, p_message text, p_related_pr integer, p_related_mig text, p_in_reply_to bigint, p_meta jsonb)` | bigint |  |
| `bot_chat_resolve(p_id bigint, p_resolver_level text, p_resolver_lane text, p_note text)` | boolean |  |
| `broadcast_event_dirty(p_event_id bigint, p_reason text)` | void |  |
| `broker_performer_dashboard(p_performer_id bigint)` | jsonb |  |
| `broker_recent_intel(p_days_back integer, p_days_ahead integer)` | jsonb |  |
| `build_venue_section_map(p_venue_id bigint, p_platform text, p_window interval)` | integer | Config-aware builder. Loops the venue config(s) + config 0 union/fallback; each event's sections match ITS config's keys. |
| `build_venue_section_map_all(p_platform text, p_max_venues integer, p_window interval)` | integer | Bounded driver: rebuilds venue_section_map (EVO) for every has_map venue present in events. Per-venue work bounded (one venue per build call). Returns venue count processed. |
| `build_venue_section_map_batch(p_batch integer, p_window interval)` | integer | Refresh batch: builds the p_batch stalest (venue,platform) combos across evo+sg (never-built first, then oldest updated_at). Drives the initial backfill and ongoing freshness from a cron. Bounded — one venue per build call. |
| `build_watchlist_daily_email(p_user_email text, p_limit integer)` | TABLE(subject text, html text) |  |
| `bulk_generate_system_placeholder_zones()` | jsonb | One-shot: generates system_placeholder zones for every (performer, venue) tuple that has snapshot data and no curated zones. |
| `bump_share_view(p_id text)` | void |  |
| `canonical_order_status(p_source text, p_source_status text)` | jsonb |  |
| `check_chat_rate_limit(p_ip text, p_window_sec integer, p_max_calls integer)` | boolean |  |
| `check_sg_broker_429_health()` | jsonb | A1 2026-05-19: 429-rate health check. Fires bot_chat flag when last-hour pct_429 > 15% AND no open flag for this rule in last hour (hysteresis prevents spam). Scheduled @ */15 * * * *. |
| `classify_performer_categories(p_cat text, p_parent text, p_grand text)` | TABLE(top_category text, genre text, event_type text) |  |
| `classify_playoff_stage(p_event_name text)` | text |  |
| `classify_tennis_tour(p_name text)` | text |  |
| `classify_tournament_sport(p_name text)` | text |  |
| `classify_zone_canonical(p_section text)` | text |  |
| `collect_listings_featured_refresh(p_max_events integer)` | integer | Refreshes TEvo /v9/ticket_groups for up to p_max_events NYC events with owned>100 in 24h-90d window. Fires per-event edge function calls via _cron_invoke_edge_fn. Returns count of events dispatched. Called by cron collect-listings-featured-10min every 10 min. |
| `collector_band(p_source text, p_scope text, p_hours numeric)` | TABLE(band text, required_min integer) |  |
| `collector_band(p_source text, p_scope text, p_hours numeric, p_owned boolean)` | TABLE(band text, required_min integer) |  |
| `compute_alerts_tick()` | jsonb |  |
| `compute_buyer_sentiment(p_event_id bigint)` | numeric |  |
| `compute_event_breakdowns(p_event_id bigint, p_captured_at timestamp with time zone)` | jsonb | Computes zone + section metrics for one event snapshot. Non-fatal: self-caps at 6s (under the 8s authenticator/PostgREST ceiling), traps query_canceled explicitly, and soft-fails a slow step rather than erroring, so collect-listings no longer 502s on heavy events after pricing has already persisted. Returns zones_written/sections_written + zone_ok/section_ok status flags. For out-of-band recompute of heavy events, call compute_event_zone_metrics / compute_event_section_metrics directly (e.g. backfill_stale_zone_metrics) under a longer budget. |
| `compute_event_listing_snapshot(p_slot text)` | integer | UPDATED 2026-05-27: added TD platform columns (td_sh/gt/vd listings + medians). Aggregates ticketsdata_listings_snapshots (last 12h) per event per platform. td_combined_median = LEAST(sh, gt, vd) excl. NULLs. Runs at 7:30/13:30/19:30 UTC via event_snapshot_morning/midday/evening crons. |
| `compute_event_movers_index(p_source text, p_window_days integer)` | integer |  |
| `compute_event_movers_index_all()` | void | Run all 30 source×window combos (6 sources × 5 windows). FIXED 2026-05-28 (mig 290000): global past-event purge runs before the loop to clear stale rows from failed compute runs and inter-cron-fire gaps. Each combo wrapped in BEGIN/EXCEPTION so one failure does not abort all. |
| `compute_event_nonowned_median(p_event_id bigint)` | TABLE(updated_at timestamp with time zone, nonowned_median numeric) |  |
| `compute_event_section_metrics(p_event_id bigint, p_captured_at timestamp with time zone)` | integer | Idempotent. Computes and upserts section_metrics rows for one (event_id, captured_at). Tags each section with its dominant zone (curated > fallback > unmapped). |
| `compute_event_splits_metrics(p_event_id bigint)` | TABLE(updated_at timestamp with time zone, splits_min_q integer, with_singles integer, with_pairs integer, no_split integer) |  |
| `compute_event_zone_metrics(p_event_id bigint, p_captured_at timestamp with time zone)` | integer | Idempotent: computes and upserts zone_metrics rows for a given (event_id, captured_at) by reading listings_snapshots already written at that tick. |
| `compute_nws_impact_tier(p_event text)` | text |  |
| `compute_sg_fill_rate()` | integer |  |
| `create_system_aq_event(p_source text, p_event_name text, p_venue_name text, p_event_date timestamp with time zone, p_source_event_id bigint)` | text | Fallback when match_to_aq_event_id returns empty. Inserts a SYS-prefixed aq_event_map row keyed by md5(name|venue|date) for stability across calls. Operator can later promote/merge system_seed rows to aq_curated. |
| `create_user_alert(p_scope_type text, p_scope_id bigint, p_metric_key text, p_operator text, p_threshold numeric, p_params jsonb, p_channels text[], p_notify_email text, p_notify_phone text, p_cooldown_minutes integer, p_scope_label text, p_expires_at timestamp with time zone)` | user_alerts |  |
| `cron_last_fire(p_jobname text)` | timestamp with time zone |  |
| `cron_resume_with_gate(p_jobname text)` | text |  |
| `cron_should_fire(p_jobname text)` | boolean |  |
| `cross_source_match_tick()` | jsonb |  |
| `cross_source_venue_resolve(p_venue_name text, p_city text, p_state text)` | bigint |  |
| `d2_cron_freshness()` | TABLE(source text, jobname text, phase text, schedule text, active boolean, last_run timestamp with time zone, last_status text) | Per-source cron freshness for the D2 dashboard chips. SECDEF + body-guarded (B1-NEXT-1 closure). SG source maps to broker firehose crons (sg_broker_sales_queue_30min / sg_priority_sales_process_1min) post the 2026-05-16 dashboard rewire. |
| `d2_metrics_biggest_sales(p_since timestamp with time zone, p_limit integer)` | TABLE(source text, source_order_id text, tevo_event_id bigint, event_name text, event_date timestamp with time zone, gross_value numeric, quantity bigint, canonical_status text, created_at timestamp with time zone) |  |
| `d2_metrics_hot_events(p_start timestamp with time zone, p_end timestamp with time zone, p_limit integer)` | TABLE(tevo_event_id bigint, event_name text, event_date timestamp with time zone, recent_count bigint, recent_gross numeric, fulfilled_count bigint, last_order_at timestamp with time zone) |  |
| `d2_metrics_hourly_buckets(p_start timestamp with time zone, p_end timestamp with time zone)` | TABLE(hour_bucket timestamp with time zone, source text, orders_count bigint, gross numeric, fulfilled_gross numeric) |  |
| `d2_metrics_sales_gaps(p_lookback_hours integer, p_min_gap_minutes integer)` | TABLE(source text, gap_start timestamp with time zone, gap_end timestamp with time zone, gap_minutes numeric) |  |
| `d2_metrics_top_events(p_start timestamp with time zone, p_end timestamp with time zone, p_limit integer)` | TABLE(tevo_event_id bigint, event_name text, event_date timestamp with time zone, total_gross numeric, total_count bigint, fulfilled_count bigint) |  |
| `d2_metrics_window(p_start timestamp with time zone, p_end timestamp with time zone)` | TABLE(source text, orders_count bigint, fulfilled_count bigint, gross_total numeric, fulfilled_gross numeric, qty_total bigint, fulfilled_qty bigint) |  |
| `delete_user_alert(p_id bigint)` | boolean |  |
| `derive_event_lifecycle(p_event_id bigint)` | TABLE(status text, confidence numeric, reasons text[], is_active boolean, hrs_since_seen numeric, hrs_to_event numeric, ghost_score integer) | Classify an event as active / ghost_eliminated / completed / postponed / cancelled / unknown. Used to sort ghost playoff games (eliminated team brackets) out of broker terminal live surfaces. See migration 20260509050000 for rule definitions. |
| `derive_zone_fallback(p_section text, p_row text)` | text |  |
| `dispatch_watchlist_daily()` | integer |  |
| `ensure_major_league_watchlist_coverage()` | TABLE(performers_added integer, venues_added integer) |  |
| `espn_has_live_tracked_game()` | boolean | True when an ESPN-referenced (team_xref) team has an in-window, non-final game. Gates espn-live-score-poll. |
| `espn_scoreboard_process()` | TABLE(processed integer, events_upserted integer) | Drains espn_scoreboard_pending into espn_event_date_lookup. Cron-scheduled every 5 min. |
| `espn_scoreboard_queue(p_lookahead_days integer)` | integer | Fires ESPN scoreboard pulls for 6 leagues (MLB chunked into 2 calls to dodge the 1000-event scoreboard cap). 7 calls per tick, every 4 hours = 42 calls/day. Cron: espn_scoreboard_queue_4h. |
| `espn_tournament_process()` | TABLE(processed integer, events_upserted integer) |  |
| `espn_tournament_queue(p_lookahead_days integer)` | integer |  |
| `evaluate_user_alerts(p_lookback_hours integer)` | integer |  |
| `evaluate_user_signal_alerts(p_lookback_hours integer)` | integer |  |
| `event_alert_check(p_event_id bigint, p_metric_key text, p_operator text, p_threshold numeric, p_lookback_hours integer)` | TABLE(fired boolean, cur numeric, pct numeric) |  |
| `event_digest_fragment(p_event_id bigint)` | text |  |
| `event_has_s4k_inventory(p_event_id bigint, p_min_tickets integer)` | boolean | Cheap predicate. Used by chat fn (next session) to filter RESOLVED_CONTEXT / COMPREHENSIVE_SEARCH_CONTEXT before surfacing — events without S4K inventory get hidden. |
| `event_metric_value(p_event_id bigint, p_metric_key text, p_at timestamp with time zone)` | numeric |  |
| `event_signal_detail(p_event_id bigint, p_metric_key text)` | text |  |
| `event_signal_latest_at(p_event_id bigint, p_metric_key text)` | timestamp with time zone |  |
| `event_signal_value(p_event_id bigint, p_metric_key text, p_at timestamp with time zone)` | numeric |  |
| `event_watchlist_add_world_cup()` | integer |  |
| `event_watchlist_list()` | jsonb |  |
| `event_watchlist_set(p_event_id bigint, p_on boolean)` | boolean |  |
| `event_watchlist_set_alert(p_event_id bigint, p_on boolean)` | boolean |  |
| `event_watchlist_set_alert_sg(p_sg_event_id bigint, p_on boolean)` | boolean |  |
| `event_watchlist_set_sg(p_sg_event_id bigint, p_on boolean)` | boolean |  |
| `evo_discover_new_events()` | void | Phase 1 stub: compute EVO coverage stats from local DB, log to bot_chat. Runs daily at 8am UTC (4am ET). No external API calls. Phase 2 will add TEvo /v9/events HTTP discovery + aq_event_map writes. |
| `evo_event_backfill_process()` | TABLE(processed integer, persisted integer) |  |
| `evo_event_backfill_queue(p_limit integer)` | integer |  |
| `evo_listings_poll_tick(p_max integer)` | integer |  |
| `evo_orders_process()` | TABLE(processed integer, orders_persisted integer, items_persisted integer) | Persist EVO orders + items from pg_net responses. Items are delete+reinsert per order so adds/removes reflect cleanly. Restored after audit caught regression where items block was dropped during cron rebuild. |
| `evo_orders_queue(p_pages integer)` | integer | Server-side EVO orders pull via TEvo HMAC + pg_net. Replaces the broken Railway-bound /api/admin/collect-orders cron. Fires p_pages pages of /v9/orders?per_page=100. Pair with evo_orders_process() to persist. |
| `evo_orphan_event_resolve()` | TABLE(orphans_seen integer, attempts_logged integer) |  |
| `evo_sg_discovery_gaps()` | integer | Detect EVO/SG/TD market coverage and opportunity gaps. gap_types: sg_no_evo | td_sh/gt_no_evo | td_sh_no_gt | evo_no_sg | value_gap_large | fill_rate_spike. Upserts discovery_gap_alerts. Runs daily 9am UTC via discovery_gap_refresh cron. |
| `exos_announce_to_followers(p_event_id uuid)` | integer |  |
| `exos_assert_purchase_limit(p_event_id uuid, p_buyer uuid, p_qty integer)` | void |  |
| `exos_cancel_transfer(p_transfer_id uuid)` | void |  |
| `exos_check_in_ticket(p_ticket_id uuid, p_source text, p_verification text, p_barcode_payload text)` | jsonb |  |
| `exos_claim_invite(p_token uuid)` | uuid |  |
| `exos_claim_transfer(p_transfer_id uuid)` | uuid |  |
| `exos_create_org(p_name text, p_slug text)` | uuid |  |
| `exos_create_transfer(p_ticket_id uuid, p_receiver_email text)` | uuid |  |
| `exos_follow_org(p_org_id uuid)` | void |  |
| `exos_has_org_role(p_org_id uuid, p_roles text[])` | boolean |  |
| `exos_holds_ticket(p_event_id uuid)` | boolean |  |
| `exos_is_admin()` | boolean |  |
| `exos_issue_ticket_to_email(p_event_id uuid, p_tier_id uuid, p_recipient_email text, p_qty integer, p_order_ref text)` | uuid[] |  |
| `exos_mail_claim_batch(p_limit integer, p_max_attempts integer, p_stuck_minutes integer)` | TABLE(id uuid, to_email text, subject text, html text, attempts integer) |  |
| `exos_mail_mark(p_id uuid, p_ok boolean, p_error text, p_max_attempts integer)` | void |  |
| `exos_mint_tickets(p_event_id uuid, p_tier_id uuid, p_quantity integer, p_order_ref text, p_price_paid numeric, p_promoter_id text)` | uuid[] |  |
| `exos_notify_event_holders(p_event_id uuid, p_template text)` | integer |  |
| `exos_queue_mail(p_template text, p_ref_id uuid)` | uuid | D4 mig 20260520160000: queue transactional mail via server-derived recipient.    Client supplies template name + ref_id for the related record. to_email and    html body are derived server-side — no open relay. SECDEF; only service_role    reads the exos_mail table directly (the drainer). B1 SEC-HIGH fix (bot_chat #438). |
| `exos_queue_ticket_issued(p_ticket_id uuid)` | uuid |  |
| `exos_redeem_discount_code(p_event_id uuid, p_code text)` | jsonb |  |
| `exos_touch_updated_at()` | trigger |  |
| `exos_unfollow_org(p_org_id uuid)` | void |  |
| `exos_void_ticket(p_ticket_id uuid, p_reason text)` | void |  |
| `expand_user_zone_token_to_zones(p_performer_id bigint, p_venue_id bigint, p_user_token text)` | TABLE(zone_name text, source text) | #106 fix. User says lowers/100 level/courtsides → returns array of curated zone names that match the semantic family for this performer+venue. Knicks @ MSG: lowers → [100 Corner, 100 End, 100 Garbage, Risers 6-8, Risers 9+]. Falls back to canonical system zone name if no curated zones exist. |
| `external_ids_for_event(p_tevo_event_id bigint)` | jsonb |  |
| `external_ids_for_performer(p_tevo_performer_id bigint)` | jsonb |  |
| `external_ids_for_venue(p_tevo_venue_id bigint)` | jsonb |  |
| `extract_chat_entities(p_input text)` | jsonb |  |
| `extract_game_number(p_event_name text)` | integer |  |
| `extract_opponent(p_event_name text, p_team_name text)` | text |  |
| `find_competing_events(p_event_id bigint, p_radius_miles numeric, p_window_hours integer)` | TABLE(competing_event_id bigint, competing_event_name text, competing_event_at timestamp with time zone, competing_venue text, competing_city text, competing_event_type text, competing_performer text, distance_miles numeric, hours_offset numeric) | Default: 20mi radius, ±24h time window. Returns hours_offset signed. |
| `find_similar_events(p_event_id bigint, p_max integer)` | TABLE(event_id bigint, event_name text, event_date date, similarity_score numeric, same_matchup boolean, same_performer boolean, same_venue boolean) |  |
| `fred_process_pending()` | TABLE(processed integer, rows_upserted integer) |  |
| `fred_queue_all(p_months_back integer)` | integer |  |
| `generate_system_placeholder_zones(p_performer_id bigint, p_venue_id bigint)` | integer | Generates system_placeholder zones for a (performer, venue) by mining listings_snapshots. NEVER skips even if curated zones exist — curated and placeholder coexist. Curated wins on overlap via display_order priority (curated typically 1-30 vs placeholder 5-99). Placeholders cover sections curated rules miss. |
| `get_alert_metric_catalog(p_scope_type text)` | SETOF alert_metric_catalog |  |
| `get_app_secret(p_name text)` | text | Read an app secret from supabase Vault by name (whitelist-gated). Used by app.py to load API keys without Railway env vars. Service-role only. |
| `get_axs_event_price_series(p_event_id bigint, p_since timestamp with time zone)` | TABLE(captured_at timestamp with time zone, listings_count integer, median_price numeric) |  |
| `get_blind_spots_sg_selling(p_min_score integer)` | jsonb |  |
| `get_blind_spots_tevo_selling(p_min_confidence numeric, p_horizon_days integer, p_limit integer, p_venue_pattern text, p_mode text, p_band text)` | jsonb | BLIND SPOTS — TEvo SELLING, WE'RE NOT. 3-signal composite. Gates: owned=0, tickets>=25, 31-365d, US/CA, big-5 excluded, get-in>=$50. v1.5 confidence-scored. |
| `get_broker_event_detail(p_event_id bigint)` | TABLE(event_id bigint, name text, occurs_at_local text, state text, venue_id integer, venue_name text, venue_location text, primary_performer_id integer, primary_performer_name text, performer_ids integer[], configuration_id integer, configuration_name text, map_medium_url text, map_large_url text, has_seating_chart boolean, fanvenues_key text, popularity_score numeric, long_term_popularity_score numeric, curated_zones_count integer) |  |
| `get_broker_event_page(p_event_id integer, p_chart_hours integer)` | jsonb | D0 broker event detail page RPC. Flattens overview+chart_data+zones+orders+cadences into one JSONB. Email-gated @s4kent.com. |
| `get_broker_event_page_v2(p_event_id integer, p_chart_hours integer)` | jsonb | D0 Phase 2a Event Detail RPC. Extends v1 with sales_tape (SG, deduped on sg_sale_id), weather (forecast+obs+NWS, hidden when indoor), espn (standings+injuries+recent_results, gated on espn xref), event_alerts (chart markers), sg_side_by_side (NULL when no SG bridge), splits (owned vs market density), freshness (per-source MAX captured_at). Email-gated to @s4kent.com. |
| `get_broker_event_page_v3(p_event_id integer, p_chart_hours integer)` | jsonb | D0 Phase 2a v3 — extends v2 with 9 enrichment keys: performer, velocity, sg_broker_sales, sg_listings_summary, competing_events, cross_source_orders, recent_listings, zone_deltas, performer_espn_context. Email-gated to @s4kent.com. |
| `get_broker_events_upcoming(p_search text, p_performer_id integer, p_venue_id integer, p_days_ahead integer, p_limit integer, p_offset integer)` | TABLE(event_id bigint, name text, occurs_at_local text, venue_name text, primary_performer_name text, configuration_id integer, configuration_name text, has_seating_chart boolean, map_medium_url text, long_term_popularity_score numeric) |  |
| `get_broker_movers_home(p_window_hours integer)` | jsonb |  |
| `get_broker_performer_index()` | jsonb |  |
| `get_broker_performer_page(p_performer_id integer)` | jsonb |  |
| `get_broker_venue_index()` | jsonb |  |
| `get_broker_venue_page(p_venue_id integer)` | jsonb |  |
| `get_cached_ticket_groups(p_event_id bigint)` | jsonb |  |
| `get_chat_suggestion_chips(p_count integer, p_min_tickets integer)` | TABLE(event_id bigint, name text, what text, when_local text, where_venue text, where_city text, min_price numeric, popularity numeric, s4k_listings integer, s4k_total_tickets integer, has_seating_chart boolean, suggestion_kind text) |  |
| `get_event_all_source_listing_metrics(p_event_id integer)` | jsonb |  |
| `get_event_amalgam(p_event_id bigint)` | TABLE(amalgam_getin numeric, amalgam_median numeric, amalgam_source_count integer, sources text[], evo_getin numeric, evo_median numeric, evo_count integer, sg_getin numeric, sg_median numeric, sg_count integer, sh_getin numeric, sh_median numeric, sh_count integer, gt_getin numeric, gt_median numeric, gt_count integer, vd_getin numeric, vd_median numeric, vd_count integer, tp_getin numeric, tp_median numeric, tp_count integer, tm_getin numeric, tm_median numeric, tm_count integer) | Live cross-source amalgam for one event (TEvo event_id): floor / count-weighted median / source_count / sources[] + per-source getin/median/count breakdown. Same formula as the stored amalgam_* columns on event_listing_snapshot_daily, computed from the latest live per-source state. |
| `get_event_assets_public(p_event_id bigint)` | jsonb |  |
| `get_event_chart_extended(p_event_id integer, p_chart_hours integer, p_espn_home_team text, p_espn_away_team text)` | jsonb | D0 event chart extension — SG-side series (listings median/owned/count + sales median/count) + SeatData sales (sd_sales_median/sd_sales_count, DISTINCT ON content_hash) + OUR orders sell-through (orders_count = EVO+TickPick+Vivid tickets sold/bucket, sold-status filtered) + 2 ESPN annotation arrays. SeatData/orders keyed by tevo_event_id (render even when SG hidden). DISTINCT ON sg_sale_id|sglid|content_hash mandatory. TickPick liveness uses order_status, NOT status. Email-gated. |
| `get_event_context(p_event_id bigint)` | jsonb | Single-row jsonb summary of every context dimension. Now 18 keys including tournament (F1/tennis/golf/LIV ESPN tournament context). |
| `get_event_cross_broker_orders_full(p_event_id integer, p_limit integer)` | jsonb | D0 event-page tabs (round 2) — TickPick + Vivid orders UNION per event (TP direct tevo_event_id; Vivid via aq_event_map bridge, capped 500). Email-gated. |
| `get_event_cross_source_metrics(p_event_id integer)` | jsonb | Cross-source metrics: TEvo event_metrics + SG seatgeek_event_metrics + TD ticketsdata_listings_snapshots. TD stats: last 24h non-parking snapshots. Returns td (per-platform), td_agg (aggregate), and td column in rows[]. Updated 2026-05-27 (20260527140000). |
| `get_event_evo_listings_full(p_event_id integer, p_limit integer)` | jsonb | D0 event-page tabs — full TEvo listings for an event (deduped on tevo_ticket_group_id, last 7d, capped 500, owned-first sort). Email-gated. |
| `get_event_evo_orders_full(p_event_id integer, p_limit integer)` | jsonb | D0 event-page tabs (round 2) — our office TEvo orders ⨯ items per event (capped 500). Email-gated. |
| `get_event_listings_public(p_event_id bigint, p_zone text, p_min_qty integer, p_max_price numeric, p_limit integer, p_include_all boolean)` | TABLE(ticket_group_id bigint, section text, seat_row text, quantity integer, retail_price numeric, format text, splits integer[], instant_delivery boolean, wheelchair boolean, is_owned boolean, brokerage_provenance text, resolved_zone text) |  |
| `get_event_movers(p_window_hours integer)` | TABLE(event_id bigint, name text, primary_performer_id bigint, primary_performer_name text, venue_id bigint, venue_name text, occurs_at_local text, latest_at timestamp with time zone, prior_at timestamp with time zone, cur_market_med numeric, prev_market_med numeric, cur_owned_med numeric, prev_owned_med numeric, cur_market_tix integer, prev_market_tix integer, cur_owned_tix integer, prev_owned_tix integer, cur_owned_share numeric) | v3: + cur_owned_share so the UI can flag we-are-the-market events (owned_share >= 30% means screen quote is reflexive). |
| `get_event_movers_index_summary(p_source text, p_window_days integer)` | TABLE(source text, window_days integer, category text, index_size bigint, avg_signal_score numeric, avg_price_delta_pct numeric, avg_data_coverage numeric, entries_24h bigint, exits_24h bigint, last_computed_at timestamp with time zone) | Index health summary: one row per (source, window_days, category). Tracks size, 24h entry/exit turnover, avg signal score and data coverage. data_coverage_pct < 100 means some events lacked enough history for full SMA. Added 2026-05-27 (mig 260000). |
| `get_event_movers_v2(p_source text, p_window_days integer, p_category text, p_limit integer)` | TABLE(source text, window_days integer, category text, rank integer, event_id bigint, event_name text, venue_name text, occurs_at text, days_to_event integer, entry_price numeric, cur_price numeric, price_delta_pct numeric, cur_owned integer, owned_delta numeric, cur_tix integer, tix_delta numeric, signal_score numeric, days_in_index numeric, data_coverage_pct numeric, evo_median numeric, sg_median numeric, td_sh_median numeric, td_gt_median numeric, td_vd_median numeric, sh_vs_evo_spread numeric, gt_vs_sh_spread numeric, vd_vs_sh_spread numeric) | v2 movers RPC: per-event rows from event_movers_index with cross-source spread columns. p_source + p_window_days are required; p_category=NULL returns all categories up to p_limit rows (ordered category, rank). FIXED 2026-05-28 (mig 290000): added sg_datetime_utc > now() to exclude past events; replaced GREATEST(0,...) with plain FLOOR so days_to_event is accurate for today events. |
| `get_event_movers_with_sg(p_window_hours integer)` | TABLE(event_id bigint, name text, primary_performer_id bigint, primary_performer_name text, venue_id bigint, venue_name text, occurs_at_local text, latest_at timestamp with time zone, prior_at timestamp with time zone, cur_market_med numeric, prev_market_med numeric, cur_owned_med numeric, prev_owned_med numeric, cur_market_tix integer, prev_market_tix integer, cur_owned_tix integer, prev_owned_tix integer, sg_sales_window integer) | Top movers + per-event SG sales count over p_window_hours. A1 2026-05-19 perf rewrite (mig 20260519160000): count(DISTINCT) hash-agg path instead of Sort+Unique+COUNT(*), make_interval typed-interval. Measured 358ms standalone (was 60s+ timeout post-burst-fix when firehose grew to 23k rows/24h). DISTINCT counted on sg_sale_id per PROJECT_BIBLE.md §3 (each logical sale re-inserts every poll cycle). |
| `get_event_sd_chart_series(p_event_id integer, p_chart_hours integer)` | jsonb |  |
| `get_event_sd_sales_full(p_event_id integer, p_limit integer, p_window_days integer)` | jsonb |  |
| `get_event_seatdata_sales_full(p_event_id integer, p_limit integer, p_window_days integer)` | jsonb | D0 event-page tabs — full SeatData sales for an event (DISTINCT ON content_hash, window 1-90d, UNCAPPED default 100000). Keyed on tevo_event_id (no SG bridge). Email-gated. |
| `get_event_section_map(p_event_id bigint)` | TABLE(platform text, section_raw text, seatmap_key text, match_method text, confidence numeric, seen_listings integer, configuration_id integer) | Terminal seat-map panel API: config-aware section->seatmap_key crosswalk for an event (resolves events.configuration_id, falls back to union bucket 0). Email-gated @s4kent.com. |
| `get_event_sg_listings_full(p_event_id integer, p_limit integer)` | jsonb | D0 event-page tabs — full SG listings for an event (deduped on sglid, last 7d, capped 500). Email-gated. |
| `get_event_sg_sales_full(p_event_id integer, p_limit integer, p_window_days integer)` | jsonb | D0 event-page tabs — full SG sales for an event (DISTINCT ON sg_sale_id, window 1-90d, capped 500). Uses idx_sg_sales_sg_event_id_time. days_to_event_at_sale computed inline (column not in table). Email-gated. |
| `get_event_sg_seller_listings_full(p_event_id integer, p_limit integer)` | jsonb |  |
| `get_event_sg_seller_orders_full(p_event_id integer, p_limit integer)` | jsonb | D0 event-page tabs (round 2) — our SG SellerDirect orders per event (bridge via seatgeek_event_xref, capped 500). Email-gated. |
| `get_event_sg_zones_splits(p_event_id integer)` | jsonb |  |
| `get_event_td_listings(p_tevo_event_id bigint, p_platform text, p_hours integer)` | TABLE(section text, "row" text, quantity integer, list_price numeric, price_with_fees numeric, is_parking boolean, inventory_type text, captured_at timestamp with time zone) |  |
| `get_event_td_pull_health(p_event_id bigint)` | jsonb | D0 TD Markets tab — per-event-per-platform TD pull timing + health (cron timers panel). Resolves tevo_event_id -> aq_event_map -> ticketsdata_event_xref (last_fetched/enqueued, enqueues_today, active) + latest td_pull_queue row (status/rows/latency/interval). Both source tables are service-role-walled; this SECDEF wrapper exposes them read-only. Email-gated @s4kent.com, STABLE. D0-authored; A1 applied 2026-05-30. |
| `get_event_weather_localized(p_event_id integer)` | jsonb |  |
| `get_event_zones_public(p_event_id bigint, p_include_all boolean)` | TABLE(zone_name text, zone_source text, display_order integer, listings integer, total_tickets integer, cheapest numeric, median numeric, most_expensive numeric) |  |
| `get_event_zones_rollup(p_event_id bigint, p_owned_only boolean)` | TABLE(zone text, source text, tickets bigint, min_retail numeric, max_retail numeric) |  |
| `get_events_by_performer_public(p_performer_id bigint, p_days_ahead integer, p_limit integer)` | TABLE(event_id bigint, name text, what text, when_local text, where_venue text, where_city text, min_price numeric, s4k_total_tickets integer, has_seating_chart boolean, popularity numeric) |  |
| `get_events_by_venue_public(p_venue_id bigint, p_days_ahead integer, p_limit integer)` | TABLE(event_id bigint, name text, what text, when_local text, where_venue text, where_city text, min_price numeric, s4k_total_tickets integer, has_seating_chart boolean, popularity numeric) |  |
| `get_health_dashboard()` | jsonb | A1 mig 20260617010000: @s4kent-gated uptime dashboard. Latest status + 24h/7d uptime % per check + web-ping results + 24h overall timeline. Powers static/terminal/health.html. |
| `get_macro_series(p_series_id text, p_limit integer)` | jsonb | D0 Performer page MACRO OVERLAY (music variant). Recent FRED observations for one series (default UMCSENT) from admin-walled macro_indicators, oldest->newest. SECDEF, read-only, @s4kent gated, p_limit clamped [1,600]. D0-authored; A1 applied 2026-05-31. |
| `get_or_authorize_pull(p_event_id bigint, p_source text, p_requester text, p_max_age_seconds integer)` | jsonb |  |
| `get_performer_assets_public(p_performer_id bigint)` | jsonb |  |
| `get_performer_landing_public(p_performer_id bigint)` | TABLE(performer_id bigint, name text, slug text, category_name text, top_category text, genre text, popularity numeric, home_venue_id bigint, home_venue_name text, upcoming_first timestamp with time zone, upcoming_last timestamp with time zone) |  |
| `get_performer_metrics_daily(p_performer_id bigint, p_days integer, p_split text)` | SETOF performer_metrics_daily |  |
| `get_performer_narrative(p_performer_id bigint)` | jsonb | D0 Performer page NARRATIVE block. Wikipedia bio (performer_wikipedia, latest non-rejected) + rivalries (sporting_rivalries). Both admin-walled; SECDEF wrapper, read-only, @s4kent gated. D0-authored; A1 applied 2026-05-31. |
| `get_performers_by_league(p_league text)` | TABLE(performer_id bigint, performer_name text, league text, home_venue_id bigint, home_venue_name text, home_events integer, home_market_med numeric, home_owned_med numeric, home_market_tix bigint, home_owned_tix bigint, home_first_event text, home_last_event text, home_prev_market_med numeric, home_prev_owned_med numeric, road_events integer, road_market_med numeric, road_owned_med numeric, road_market_tix bigint, road_owned_tix bigint, road_first_event text, road_last_event text, road_prev_market_med numeric, road_prev_owned_med numeric) | v4.1: ghost filter tightened to 48h (was 7d). Catches Boston-Knicks ghosts after R1 resolved. |
| `get_player_info(p_query text, p_limit integer)` | jsonb |  |
| `get_recent_team_changes(p_since timestamp with time zone, p_limit integer)` | jsonb |  |
| `get_returning_entities(p_min_gap_days integer, p_source text, p_entity_type text, p_limit integer)` | jsonb |  |
| `get_returning_entity_events(p_source text, p_entity_type text, p_entity_id text, p_limit integer)` | jsonb |  |
| `get_sg_blindspot_evo_tracking(p_limit integer)` | jsonb |  |
| `get_sg_market_chart(p_offset integer, p_limit integer)` | jsonb | Returns {chart_date,total,rows[]} for the latest sg_market_chart day, paged by rank (offset/limit). Powers the terminal home "TOP 50 — SG SELLING, WE'RE NOT IN" panel. Email-gated @s4kent.com. |
| `get_team_context(p_performer_id bigint)` | jsonb | Full team context: standings + playoff series + wiki summary + active rivalries + marquee-game flag for next opponent + recent news + injury count + roster. Single shared helper for both broker terminal and retail chatbot. |
| `get_team_playoff_context(p_performer_id bigint)` | jsonb | Playoff next-game + recent results + series record. A1 2026-05-18 (mig 20260519180002): co-filter espn_event_snapshots by (espn_team_id, espn_league) — prevents cross-league team_id collision pollution. |
| `get_team_roster(p_performer_id bigint)` | jsonb |  |
| `get_venue_assets_public(p_venue_id bigint)` | jsonb |  |
| `get_venue_metrics_daily(p_venue_id bigint, p_days integer)` | SETOF venue_metrics_daily |  |
| `get_wc_markets(p_sg_event_id bigint)` | TABLE(source text, getin numeric, median numeric, listings integer, last_pull timestamp with time zone) |  |
| `get_wc_price_board()` | SETOF wc_price_daily |  |
| `get_wc_price_daily(p_sg_event_id bigint, p_days integer)` | SETOF wc_price_daily |  |
| `get_wc_sg_listings(p_sg_event_id bigint, p_limit integer)` | TABLE(section text, "row" text, quantity integer, splits text, retail_price_all_in numeric, broadcast_price numeric, is_broker_owned boolean, captured_at timestamp with time zone) |  |
| `get_wc_sg_sales(p_sg_event_id bigint, p_days integer, p_limit integer)` | TABLE(sale_at_utc timestamp with time zone, section text, "row" text, quantity integer, broadcast_price numeric) |  |
| `get_wiki_context(p_performer_id bigint)` | jsonb | Wikipedia-derived context for a performer. Used by both products. |
| `gin_extract_query_trgm(text, internal, smallint, internal, internal, internal, internal)` | internal |  |
| `gin_extract_value_trgm(text, internal)` | internal |  |
| `gin_trgm_consistent(internal, smallint, text, integer, internal, internal, internal, internal)` | boolean |  |
| `gin_trgm_triconsistent(internal, smallint, text, integer, internal, internal, internal)` | "char" |  |
| `gtrgm_compress(internal)` | internal |  |
| `gtrgm_consistent(internal, text, smallint, oid, internal)` | boolean |  |
| `gtrgm_decompress(internal)` | internal |  |
| `gtrgm_distance(internal, text, smallint, oid, internal)` | double precision |  |
| `gtrgm_in(cstring)` | gtrgm |  |
| `gtrgm_options(internal)` | void |  |
| `gtrgm_out(gtrgm)` | cstring |  |
| `gtrgm_penalty(internal, internal, internal)` | internal |  |
| `gtrgm_picksplit(internal, internal)` | internal |  |
| `gtrgm_same(gtrgm, gtrgm, internal)` | internal |  |
| `gtrgm_union(internal, internal)` | gtrgm |  |
| `haversine_miles(p_lat1 numeric, p_lon1 numeric, p_lat2 numeric, p_lon2 numeric)` | numeric | Great-circle distance between two lat/lon points in miles. Used for venue radius queries. |
| `health_collect_web_probes()` | integer |  |
| `health_fire_web_probes()` | integer |  |
| `health_snapshot_pipeline()` | integer |  |
| `health_tick()` | void |  |
| `is_north_america_venue(p_location text)` | boolean |  |
| `is_rivalry_game(p_performer_a bigint, p_performer_b bigint)` | jsonb | Quick check whether a matchup is a rivalry. Returns is_rivalry/is_marquee/intensity. |
| `link_aq_tevo_from_events()` | integer |  |
| `list_user_alerts(p_scope_type text, p_scope_id bigint)` | SETOF user_alerts |  |
| `listings_deltas_backfill_chunked(p_max_events integer)` | TABLE(source_table text, events_processed integer, rows_updated integer, events_remaining integer) |  |
| `macro_context_at(p_ts timestamp with time zone)` | TABLE(series_id text, value numeric, observation_date date, realtime_start date) | All series, as-of-time. One row per series_id with the latest revision known at <ts>. |
| `macro_value_as_of_observed(p_series text, p_ts timestamp with time zone)` | numeric | Retrospective macro reading by observation_date. WARNING: lookahead-biased for backtests (uses values that may have been published AFTER p_ts). Use macro_value_at() for strict no-lookahead. |
| `macro_value_at(p_series text, p_ts timestamp with time zone)` | numeric | As-of-time macro reading. Returns the value of <series> that was published on or before <ts>. No lookahead bias — safe for backtests. |
| `map_tevo_category_to_genre(p_cat_name text, p_parent text)` | text |  |
| `map_tevo_top_category(p_cat_name text, p_parent text, p_grandparent text)` | text |  |
| `map_top_category_to_event_type(p_top text)` | text |  |
| `mark_event_chat_tracked(p_event_id bigint)` | void |  |
| `master_cascade_2min()` | jsonb |  |
| `match_events_to_espn_tick(p_limit integer)` | TABLE(considered integer, matched integer, no_data integer, skipped integer) | Strict in-DB matcher: per tick, resolves up to N TEvo events to their correct ESPN event_id via (home_team_id, away_team_id, league, date). Idempotent — skips events already matched by us (match_method LIKE in_db_strict_v%). Cron-scheduled every 10 min, default N=10 = 60/hr. |
| `match_listings_to_sg_tick()` | integer | SG↔TEvo listing matcher (broker_section_row_qty method). Mirrors event matcher pattern. |
| `match_news_keywords(p_text text)` | jsonb | Returns matched keywords + per-category weight totals for a given text. |
| `match_performer_zone(p_performer_id bigint, p_venue_id bigint, p_section text, p_row text)` | text |  |
| `match_tevo_to_espn_tournaments()` | TABLE(matched integer, attempted integer) |  |
| `match_tevo_to_sg_canonical(p_event_name text, p_venue_name text, p_event_date timestamp with time zone, p_venue_id bigint, p_lat numeric, p_lon numeric)` | TABLE(sg_event_id bigint, confidence numeric, match_method text) | Mirror of match_to_aq_event_id but targets sg_events_canonical. Default mapper for linking TEvo events to SG canonical when no direct ID match exists. Returns empty when no match within 6h venue+date window or 1km coord+date window. |
| `match_to_aq_event_id(p_source text, p_source_event_id bigint, p_event_name text, p_venue_name text, p_event_date timestamp with time zone, p_lat numeric, p_lon numeric, p_source_venue_id bigint)` | TABLE(aq_short_event_id text, confidence numeric, match_method text) |  |
| `match_unmatched_listings_chunked(p_max_events integer, p_create_synthetic boolean)` | TABLE(source_table text, events_processed integer, listings_updated integer, synthetic_created integer, events_remaining integer) |  |
| `match_unmatched_orders_sweep(p_max_per_table integer, p_create_synthetic boolean)` | TABLE(table_name text, rows_examined integer, rows_matched integer, rows_synthetic integer, rows_unmatched integer) | Hourly sweep: iterates the 5 order/sale surfaces, runs the 4-tier matcher per row, optionally creates synthetic AQ entries on miss. Caps each table at p_max_per_table to keep runtime bounded. |
| `midnight_catchup_sweep()` | jsonb |  |
| `migration_drift_check()` | TABLE(version text, name text, applied_at timestamp with time zone, has_codified boolean, note text) | Returns last 100 applied migrations (prod-side). CI joins against on-disk supabase/migrations/*.sql to detect drift. |
| `next_performers_to_crawl(p_limit integer)` | TABLE(performer_id bigint, performer_name text) |  |
| `next_venues_to_crawl(p_limit integer)` | TABLE(venue_id bigint, venue_name text) |  |
| `normalize_sd_listing(p_event_id bigint, p_sd_zone text, p_sd_section text, p_sd_row text)` | TABLE(canonical_zone text, canonical_section text, source text) |  |
| `normalize_tournament_name(p_name text)` | text |  |
| `nws_alerts_process()` | TABLE(processed integer, alerts_upserted integer, zones_upserted integer) |  |
| `nws_alerts_queue(p_states text[])` | integer | Sweeps /alerts/active?area=ST for venue-relevant states only (derived from venue_assets.ugc_county_code). Pass p_states to override for manual ad-hoc sweeps. 0.2s pacing keeps us polite to NWS. |
| `nws_points_process()` | TABLE(processed integer, venues_updated integer) |  |
| `nws_points_queue(p_limit integer)` | integer |  |
| `orphan_backfill_sweep()` | TABLE(evo_deleted integer, sg_deleted integer) |  |
| `performer_metric_value(p_performer_id bigint, p_metric_key text, p_at timestamp with time zone)` | numeric |  |
| `performer_wiki_tick(p_limit integer)` | jsonb |  |
| `populate_seatgeek_historic_sales()` | jsonb | Rebuild seatgeek_historic_sales from seatgeek_orders. Idempotent — uses sg_order_row_id unique key to upsert. Auto-fills seatgeek_performer_xref. |
| `process_performer_wiki_searches()` | TABLE(processed integer, hits integer, misses integer, retries integer, summary_fired integer) |  |
| `process_performer_wiki_summaries()` | integer |  |
| `promote_performer_to_aliases(p_performer_id bigint, p_performer_name text, p_league text, p_city text)` | integer |  |
| `promote_venue_to_aliases(p_venue_id bigint, p_venue_name text, p_city text)` | integer |  |
| `put_cached_ticket_groups(p_event_id bigint, p_payload jsonb, p_ttl_seconds integer)` | void |  |
| `queue_performer_wiki_searches(p_limit integer)` | integer |  |
| `queue_sg_event_match(p_sg_event_id bigint, p_proposed_tevo_event_id bigint, p_proposed_by text, p_notes text, p_meta jsonb)` | bigint |  |
| `rebuild_sg_market_chart()` | integer | Rebuilds today's sg_market_chart: top future SG events we hold ZERO inventory in (neither SeatGeek owned_count_last_7d NOR latest EVO event_metrics.owned_tickets_count), ranked by percent_rank(7d-MA sales volume) + percent_rank(7d-MA sales median). Carries prev_rank/peak_rank/days_on_chart for Billboard-style movement. Daily cron @ 11:05 UTC. |
| `record_sg_performer_match(p_sg_name text, p_tevo_perf_id bigint, p_confidence numeric, p_match_method text, p_meta jsonb)` | void |  |
| `reddit_pending_sweep()` | integer |  |
| `reddit_process()` | TABLE(processed integer, posts_persisted integer) |  |
| `reddit_queue(p_limit integer)` | integer |  |
| `refresh_chat_corpus(p_lookback_hours integer)` | jsonb |  |
| `refresh_chat_term_freq_split(p_lookback_hours integer)` | jsonb | Splits incoming (user) vs outgoing (bot) token frequencies. Powers v28 dictionary feedback loop. |
| `refresh_concierge_events()` | jsonb |  |
| `refresh_cross_source_venue_map()` | TABLE(tevo_rows integer, sg_links integer, tickpick_links integer, vivid_links integer) |  |
| `refresh_entity_metrics_daily(p_date date)` | TABLE(performer_rows integer, venue_rows integer) |  |
| `refresh_event_competitors()` | integer |  |
| `refresh_event_movers_agg(p_window_days integer)` | integer |  |
| `refresh_latest_event_metrics()` | void | Refreshes latest_event_metrics matview. First call (relispopulated=false) does plain REFRESH; subsequent calls use CONCURRENTLY. Called by cron latest_event_metrics_refresh_5min. Statement/lock timeouts disabled in body to dodge platform 120s cap. |
| `refresh_performer_baselines()` | TABLE(rows_written integer) |  |
| `refresh_sg_broker_listings_event_metrics(p_max_events integer)` | integer | A1 2026-05-17 — populates seatgeek_event_metrics.listings_all_* + listings_owned_* per event from the SG broker firehose (seatgeek_listings_snapshots, DISTINCT ON sglid, 24h window). Hourly cron @ :47. Companion to refresh_sg_broker_sales_event_metrics (sales, @ :17). |
| `refresh_sg_broker_sales_event_metrics(p_max_events integer)` | integer |  |
| `refresh_sg_broker_sales_event_metrics_lifetime(p_max_events integer)` | integer |  |
| `refresh_sg_canonical_from_xref()` | integer |  |
| `refresh_venue_baselines()` | TABLE(rows_written integer) |  |
| `refresh_wc_price_daily(p_from date, p_to date)` | integer |  |
| `refresh_world_cup_2026()` | jsonb |  |
| `reject_sg_event_match(p_pending_id bigint, p_reviewed_by text, p_reason text)` | void |  |
| `release_health_check()` | TABLE(check_class text, check_name text, status text, metric numeric, detail text) | Release-time smoke harness. Returns one row per check; status in (ok,warn,fail). Run BEFORE+AFTER each migration; new non-ok rows = regression. |
| `render_event_daily_digest(p_event_id bigint)` | TABLE(subject text, html text) |  |
| `resolve_aq_seatdata_link()` | integer |  |
| `resolve_aq_tevo_from_sources()` | integer |  |
| `resolve_seatgeek_order(p_sg_order_id text)` | seatgeek_orders_resolved |  |
| `resolve_tevo_performer_id(p_name text, p_min_sim numeric)` | bigint | Resolve a free-text performer name to a TEvo performer_id. Tries exact lower-trim first, then trigram similarity ≥ p_min_sim. Returns NULL if no candidate clears the threshold. |
| `rollup_event_section_row(p_event_id bigint, p_captured_at timestamp with time zone)` | integer |  |
| `rollup_event_section_row_batch(p_max_events integer)` | integer | A1 2026-05-18 — batch wrapper around rollup_event_section_row (single-event, mig 20260512100150). Picks events with fresh listings_snapshots in last 2h lacking a recent section rollup, processes up to p_max_events. Hourly cron @ :03. Writes source=tevo only; SG mirror pending future PR. |
| `run_daily_chat_audit(p_lookback_hours integer)` | jsonb | Daily ground-truth audit: replays bot no-results claims against listings_snapshots and flags lies by severity. |
| `safe_jsonb(p text)` | jsonb |  |
| `scope_alert_check(p_scope_type text, p_scope_id bigint, p_metric_key text, p_operator text, p_threshold numeric, p_lookback_hours integer)` | TABLE(fired boolean, cur numeric, pct numeric) |  |
| `scope_metric_value(p_scope_type text, p_scope_id bigint, p_metric_key text, p_at timestamp with time zone)` | numeric |  |
| `sd_xref_resolve()` | TABLE(orphan_xref_rows integer, sd_pulls_logged integer) |  |
| `search_events_by_date(p_date_from date, p_date_to date, p_performer_id bigint, p_city text, p_min_tickets integer, p_limit integer)` | TABLE(event_id bigint, name text, what text, when_local text, where_venue text, where_city text, min_price numeric, s4k_total_tickets integer, has_seating_chart boolean, popularity numeric) |  |
| `search_performers_for_chat(p_query text, p_limit integer)` | TABLE(performer_id bigint, display_name text, alias_kind text, league text, popularity numeric, has_upcoming boolean, sellable_events_count integer) |  |
| `search_performers_typeahead(p_query text, p_limit integer)` | TABLE(performer_id bigint, display_name text, alias_kind text, league text, popularity numeric, has_upcoming boolean, sellable_events_count integer) |  |
| `seatdata_autopoll_paid_today()` | integer |  |
| `seatdata_check_budget(p_endpoint text)` | jsonb |  |
| `seatdata_due_events(p_limit integer)` | TABLE(tevo_event_id bigint, name text, venue_name text, event_date text, venue_city text, venue_state text, sd_event_id bigint) | SeatData autopoll candidates, two tiers: (1) next 25 upcoming owned events (event_metrics owned OR our SG seller book), (2) top 40 of the daily sg_market_chart ("TOP 50 — SG SELLING, WE'RE NOT IN"), TEvo-mapped, owned-25 excluded. 25+40=65 paid salesdata pulls/day, inside the SeatData 2,000/mo cap. Staleness: unmapped <=1 search/24h; mapped refresh > 10h. |
| `seatdata_increment_budget(p_endpoint text, p_was_charged boolean)` | void |  |
| `seatmap_manifest_targets(p_limit integer)` | TABLE(venue_id bigint, configuration_id integer) |  |
| `section_in_range(p_section text, p_from text, p_to text)` | boolean |  |
| `set_limit(real)` | real |  |
| `set_user_alert_active(p_id bigint, p_active boolean)` | user_alerts |  |
| `sg_attempt_event_xref(p_sg_event_id bigint, p_sg_event_name text, p_sg_event_date date, p_sg_venue text)` | bigint | Legacy v1 SG→TEvo bridge. A1 2026-05-17: added parking guard at top — returns NULL for any name/venue containing the word parking. |
| `sg_attempt_event_xref_v3(p_sg_event_id bigint, p_sg_event_name text, p_sg_event_date date, p_sg_datetime_utc timestamp with time zone, p_sg_venue text, p_sg_venue_city text, p_sg_venue_state text, p_sg_category text)` | bigint |  |
| `sg_blindspot_poll_tick(p_max integer)` | integer |  |
| `sg_broker_60d_plus_listings_queue(p_max_events integer)` | integer | A1 mig 20260520200000: queue broker /listings for events >60d out. Default 8/call. Round-robin via last_60d_pulled_at NULLS FIRST. Skip cancelled/if-necessary; skip TBD-without-bridge. Fires under SG 10/8s bucket. |
| `sg_broker_60d_plus_sales_queue(p_max_events integer)` | integer | A1 mig 20260520200000: queue broker /sales for events >60d out. Mirror of _listings_queue. First-ever sales coverage for 60d+ events (legacy /v2/listings cron does listings only). |
| `sg_broker_listings_process(p_limit integer)` | TABLE(processed integer, listings_persisted integer) | A1 2026-05-19: 429-aware sentinel (rows_persisted = -429 on rate-limit, -1 on other non-200). |
| `sg_broker_listings_queue(p_max_events integer)` | integer | A1 2026-05-19 burst-fix: default 8 events/call (under SG 10-req quota). pg_net async = pg_sleep ineffective. 5-min cron schedule maintains throughput. |
| `sg_broker_sales_process(p_limit integer)` | TABLE(processed integer, sales_persisted integer) | A1 2026-05-19: 429-aware sentinel (rows_persisted = -429 on rate-limit, -1 on other non-200). |
| `sg_broker_sales_queue(p_max_events integer)` | integer | A1 2026-05-19 burst-fix: default 8 events/call. Same rationale as sg_broker_listings_queue. |
| `sg_canonical_auto_match_tick()` | jsonb | Master cron entry: sync seller listings -> canonical, back-sync from xref, then auto-match unmatched rows. Returns a per-tick summary as jsonb. |
| `sg_canonical_link_from_tevo_chunked(p_max_events integer)` | TABLE(events_processed integer, matches_made integer, tier_breakdown jsonb, events_remaining integer) |  |
| `sg_canonical_refresh_v2_pull(p_window_minutes integer)` | TABLE(rows_updated integer, sg_events_touched integer, window_minutes integer) | Reconciles sg_events_canonical v2-listings tracking columns from seatgeek_listings_snapshots. Called every 30 min off-cycle from the SG listings queue/process pair. Pass NULL window for full-history backfill. |
| `sg_classify_events()` | integer | REWRITTEN 2026-05-27 (mig 240000): replaced listings_snapshots 24h full-table scan. UPDATED 2026-05-28 (mig 300000): 30d ownership fallback prevents owned events being demoted to TRACK_BLINDSPOT during data gaps. COLD→COOL floor belt-and-suspenders. Root fix for May 21 dark-event vicious cycle. |
| `sg_derive_season_label(p_category text, p_date date)` | text |  |
| `sg_derive_season_type(p_category text, p_date date)` | text |  |
| `sg_event_backfill_process()` | TABLE(processed integer, persisted integer) |  |
| `sg_event_backfill_queue(p_limit integer)` | integer |  |
| `sg_extract_performers(p_name text)` | text[] | Parse sg_event_name into a text[] of performer names. Sports patterns (at / vs / @) yield {away, home}. Concerts yield {headliner} or {headliner, support}. Strips Parking / Football / (subtitle) noise. |
| `sg_force_track_listings_tick(p_max integer, p_min_remaining integer, p_repoll_min integer)` | integer |  |
| `sg_listings_floor_sweep(p_max integer, p_min_remaining integer)` | integer | Fair round-robin SG /listings selector. near(<=7d)/matched=8h(3x/day), blindspot>7d=24h(1x/day), SKIP excluded. Adaptive-gated on ratelimit-remaining. 2026-05-29. |
| `sg_listings_poll_league_tick(p_max integer, p_min_remaining integer)` | integer |  |
| `sg_listings_poll_tick(p_max integer, p_min_remaining integer, p_owned_kind text, p_rate_mult numeric)` | integer |  |
| `sg_listings_process()` | TABLE(processed integer, rows_persisted integer) |  |
| `sg_listings_queue_window(p_window text, p_min_age_seconds integer, p_limit integer)` | integer | Server-side SG /v2/listings pull with TEvo-style windowing. window: 0-24h | 1-7d | 7-30d | 30-60d | 60d+. min_age_seconds dedup so we don't pull the same event twice within the cadence window. |
| `sg_market_chart_reveal_pull(p_max integer)` | integer | Daily pre-step for the Top-50 chart: fires collect-listings for chart-eligible (non-owned, future, >=2d SG sales/7d) events mapped to TEvo but not yet collected on EVO, so true ownership surfaces before the 11:05 UTC chart rebuild. Cron @ 10:30 UTC. |
| `sg_match_event_by_venue_date(p_sg_event_id bigint, p_min_overlap numeric)` | TABLE(matched_tevo_event_id bigint, method text, confidence numeric) |  |
| `sg_match_map_tick()` | jsonb | Maps unmapped SeatGeek events via SG-anchored TicketsData /match: reap-stale -> drain -> COALESCE-fill -> fire ONE /match (serialized, budget-gated at 50%). Target priority: owned events -> AXS events -> most-owned -> soonest. Cron sg-match-map-tick every 10 min. Operator-directed 2026-06-19. |
| `sg_priority_poll_tick(p_max_polls integer)` | TABLE(rpt_tier text, rpt_scope text, rpt_events_polled integer) | A1 2026-05-19 burst-fix: default 6 polls/call (3 sales + 3 listings). pg_net async = pg_sleep removed. |
| `sg_refresh_force_track()` | jsonb |  |
| `sg_rescue_league_priority_into_state()` | integer |  |
| `sg_sales_poll_tick(p_max integer, p_horizon_days integer)` | integer |  |
| `sg_section_kind(p_section text)` | text |  |
| `sg_section_number(p_section text)` | integer |  |
| `sg_section_prefix(p_section text)` | text |  |
| `sg_seller_listings_queue(p_pages integer)` | integer | SeatGeek deprecated offset pagination 2026-05; we now fetch a single cursor-less page (per_page=500). Full cursor chain pending phase 2. |
| `sg_seller_orders_queue(p_pages integer, p_statuses text)` | integer | SeatGeek 2026-05 contract changes: status (singular, was statuses), and offset pagination deprecated. Single cursor-less page per tick. Full cursor chain pending phase 2. |
| `sg_seller_process()` | TABLE(processed integer, orders_persisted integer, listings_persisted integer) |  |
| `sg_seller_sync_and_map()` | TABLE(events_synced integer, listings_mapped integer) |  |
| `sg_tevo_search_candidates(p_limit integer, p_backoff_hours integer, p_owned_first boolean, p_owned_only boolean)` | TABLE(sg_event_id bigint, sg_event_name text, sg_event_date date, sg_datetime_utc timestamp with time zone, sg_venue_name text, sg_venue_city text, sg_venue_state text, sg_category text, owned boolean, last_result text) | SG cold-bridge candidate selection. Anti-joins sg_tevo_search_attempts, orders never-tried-first within owned-first/owned-only priority. Fixes date-front starvation in sg-to-tevo-search-bridge. See migration 20260601130000. |
| `share_links_set_updated_at()` | trigger |  |
| `show_limit()` | real |  |
| `show_trgm(text)` | text[] |  |
| `similarity(text, text)` | real |  |
| `similarity_dist(text, text)` | real |  |
| `similarity_op(text, text)` | boolean |  |
| `strict_word_similarity(text, text)` | real |  |
| `strict_word_similarity_commutator_op(text, text)` | boolean |  |
| `strict_word_similarity_dist_commutator_op(text, text)` | real |  |
| `strict_word_similarity_dist_op(text, text)` | real |  |
| `strict_word_similarity_op(text, text)` | boolean |  |
| `submit_lead_public(p_event_id bigint, p_ticket_group_id bigint, p_qty integer, p_zone text, p_max_price numeric, p_budget_basis text, p_name text, p_email text, p_phone text, p_notes text, p_channel text, p_source_url text, p_anon_id text)` | bigint |  |
| `sweep_all_expired_pg_net_pending(p_ttl_hours integer)` | TABLE(queue text, swept integer) |  |
| `sweep_duplicate_listings(p_max_events integer)` | TABLE(events_swept integer, rows_deleted integer) | Per-event sweep of consecutive-identical-state rows in listings_snapshots. Default 100 events/call. Daily cron runs the full sweep (1000 events/call). Aggregates unaffected. |
| `sweep_expired_pg_net_pending(p_table regclass, p_ttl_hours integer)` | integer |  |
| `sweep_inactive_event_states()` | TABLE(events_marked integer, by_status jsonb) |  |
| `sweep_old_bot_messages()` | void |  |
| `sweep_old_espn_injuries(p_days integer)` | integer |  |
| `sweep_old_event_section_rows(p_days integer)` | integer |  |
| `sweep_old_listings(p_days integer)` | integer | UPDATED 2026-05-27: listings_snapshots (EVO raw): 24h rolling window. event_metrics (EVO computed): 7-day rolling window (high-volume at 15-min cadence). Snapshot table (event_listing_snapshot_daily) retains 1 year for trend analysis. |
| `sweep_old_section_metrics(p_days integer)` | integer |  |
| `sweep_old_sg_listings(p_hours integer)` | integer | UPDATED 2026-05-27: 24h TTL (was 14d). Runs 4x/day at 3:15/9:15/15:15/21:15 UTC. First run deletes ~7.8 GB of backlog. Steady-state: ~108 MB/run. Trend data kept 1 year in event_listing_snapshot_daily. |
| `sweep_old_td_listings(p_days integer)` | integer | 14-day TTL sweep for ticketsdata_listings_snapshots. Ran daily at 03:30 UTC. Content-hash dedup limits growth. Returns rows deleted. |
| `sweep_terminal_event_listings(p_max_events integer)` | TABLE(events_swept integer, rows_deleted integer) | For ghost_eliminated + cancelled events, keep only the last 5 distinct captured_at pulls. Aggregate metrics preserved (event_metrics/zone_metrics/section_metrics not touched). Hourly cron. |
| `sweep_tevo_ticket_groups_cache()` | integer |  |
| `sync_canonical_to_seatgeek_orders()` | integer |  |
| `sync_sg_broker_sales_to_canonical()` | TABLE(rows_inserted integer, rows_updated integer) |  |
| `sync_sg_orders_to_canonical()` | TABLE(rows_inserted integer, rows_updated integer) |  |
| `sync_sg_seller_listings_to_canonical()` | TABLE(rows_inserted integer, rows_updated integer) | Copy distinct SG events from seatgeek_seller_listings to sg_events_canonical. Runs as part of the auto-match cron tick to pick up new seller-cron deliveries. |
| `tag_evo_only_events()` | integer |  |
| `td_api_platform(p_code text)` | text | Maps internal platform code → TicketsData API platform string. SG/seatgeek is hard-blocked (RAISE) unless td_seatgeek_allowed() — SeatGeek is sourced from its primary API, not TicketsData. See mig 20260606120000. |
| `td_apply_targets()` | integer |  |
| `td_budget_ok()` | boolean | Combined budget gate: td_daily_budget_ok() AND td_monthly_budget_ok(). All TD enqueue/pull/normalize functions call this. Daily cap: 300. Monthly cap: 9,000. |
| `td_charge_credit(p_n integer, p_event_id bigint, p_platform text, p_endpoint text, p_status_code integer, p_quota_remaining integer, p_reports integer, p_reports_remaining integer)` | void |  |
| `td_credits_this_month()` | integer |  |
| `td_credits_today()` | integer | Credits used today (UTC). Pair with td_daily_budget_ok() for 300/day soft cap. |
| `td_daily_budget_ok()` | boolean | True if today's recorded non-AXS TicketsData credits < 6,000. Budget split not yet enforced (2026-06-16). |
| `td_enqueue_peak(p_platform text, p_interval_tag text)` | integer | LIMIT 33/call: 33 × 3 platforms × 3 fires = 297 credits/day ≤ 300 cap. 3 fires/day aligned with morning/midday/evening EVO+SG snapshot slots. |
| `td_event_tier(p_dte integer)` | text |  |
| `td_events_discover(p_platform text, p_limit integer)` | integer |  |
| `td_events_discover_drain()` | integer |  |
| `td_gt_automap_check()` | jsonb |  |
| `td_gt_discover()` | integer |  |
| `td_gt_discover_drain()` | integer |  |
| `td_is_peak(p_occurs_at_local text, p_now timestamp with time zone)` | boolean |  |
| `td_log_poll_failure()` | trigger |  |
| `td_match_apply(p_min_confidence numeric, p_apply boolean)` | TABLE(aq_short_event_id text, tevo_event_id bigint, col text, old_value bigint, new_value bigint, confidence numeric, action text) |  |
| `td_match_cron_budget_ok()` | boolean | Gate for sg_match_map_tick: TD credit budget OK AND monthly /match reports < 300 (50% of the 600 automated cap). Operator-directed 2026-06-19. |
| `td_match_discovered_to_local()` | integer |  |
| `td_match_drain(p_max integer)` | integer |  |
| `td_match_enqueue(p_purpose text, p_limit integer)` | integer |  |
| `td_monthly_budget_ok()` | boolean | True if MTD recorded non-AXS TicketsData credits < 180,000. NOTE: operator-planned split (AXS 150k / rest 100k, 2026-06-16) is NOT YET ENFORCED pending review. |
| `td_normalize_drain(p_max integer)` | integer | 200→snapshots+charge; 429/503→re-queue; 402→disable crons; 401→RAISE; 403/404→deactivate xref. |
| `td_normalize_section(p_section text)` | text | Strips leading word prefix from section strings: "Bleacher 237"→"237", "Grandstand Infield 420A"→"420A". No-op for already-numeric sections. |
| `td_pending_sweep()` | void | Hourly cleanup: prune 7d+ resolved rows, reset stuck requests, deactivate past events. Platform-scoped deactivation: SH→sh_event_id, VD→vivid_event_id, TM→tm_event_id, GT+TP→sg_event_id. |
| `td_pull_drain(p_max integer)` | integer | Fires net.http_get for unfired td_pull_queue rows (FIFO). Default 5/fire = 5/sec burst. Creds via vault; never logged. |
| `td_reconcile_knicks_finals_aq()` | TABLE(action text, home_game integer, curated_aq text, target_aq text, tevo_id bigint, sg_id bigint) |  |
| `td_reports_budget_ok()` | boolean |  |
| `td_reports_this_month()` | integer |  |
| `td_seatgeek_allowed()` | boolean | Guard for the hard-disabled TicketsData-seatgeek path. Returns false unless integration_policy.td_seatgeek_emergency_override is flipped on for an emergency. SeatGeek must otherwise be sourced from brokerdata.seatgeek.com. |
| `td_seed_owned_xref(p_limit integer, p_apply boolean)` | TABLE(action text, platform text, n bigint) |  |
| `td_sg_discover(p_limit integer)` | integer |  |
| `td_sg_discover_drain()` | integer |  |
| `td_target_events()` | TABLE(aq_short_event_id text, sh_event_id bigint, vivid_event_id bigint, sg_event_id bigint) | Canonical TD tracking target set: Yankees (next 20 home), Knicks (playoff/finals), + future events at the 15 concert venues added 2026-06-05. Concert venues reached via BOTH aq_event_map link paths (direct tevo_event_id and via sg_events_canonical) so aq_curated rows with NULL sg_event_id are not skipped. |
| `td_tier_enqueue(p_platform text, p_max integer)` | integer |  |
| `td_tm_discover()` | integer |  |
| `td_tm_discover_drain()` | integer |  |
| `td_tp_discover()` | integer |  |
| `td_tp_discover_drain()` | integer |  |
| `td_tp_set_opt_in(p_tevo_event_id bigint, p_on boolean)` | integer |  |
| `td_watchlist_refresh()` | integer | Daily watchlist upsert (9 UTC). FIXED 2026-05-27: owned_tickets join now routes through sg_events_canonical.tevo_event_id → event_metrics.event_id (was broken via seatgeek_event_metrics). Populates owned_tickets + median_retail_price for enqueue priority ordering (EVO source). |
| `terminal_search(p_q text, p_limit integer)` | jsonb | D0 terminal topbar search — returns matching events (upcoming) / performers / venues. Email-gated. Cap 20/section. A1 fixup 2026-05-17: occurs_at_local is text, cast via ::timestamptz + regex guard. |
| `tevo_blindspot_discovery_enqueue()` | jsonb |  |
| `tevo_blindspot_metrics_refresh()` | jsonb |  |
| `tevo_event_id_for(p_source text, p_external_id text)` | bigint |  |
| `tevo_performer_id_for(p_source text, p_external_id text)` | bigint |  |
| `tevo_sign_get(p_path text, p_query text, p_secret text)` | text | HMAC-SHA256-base64 sign a GET to api.ticketevolution.com. Signature canonical: "GET host path?query" — ? always present even if query empty. Verified against TEvo live response. |
| `tevo_venue_id_for(p_source text, p_external_id text)` | bigint |  |
| `tg_event_alerts_auto_ack_low_signal()` | trigger |  |
| `ticketsdata_normalize_listings(p_platform text, p_content jsonb)` | TABLE(td_listing_id text, section text, "row" text, quantity integer, list_price numeric, price_with_fees numeric, is_parking boolean, raw jsonb) | Parses raw TicketsData /fetch JSON into normalized listing rows. SH: body.items[] · rawPrice. VD: items.offers[] (FIXED: no body wrapper). GT: body[] direct array · prices in DOLLARS (FIXED: not cents). Section normalization via td_normalize_section() strips VD word prefixes. TP removed; TM stub pending URL discovery. |
| `tickpick_orders_ingest_from_apps_script(p_orders jsonb, p_shared_secret text)` | TABLE(inserted integer, updated integer, skipped integer) | Apps Script → Supabase ingest path for TickPick orders. EXPLICITLY anon-callable (Apps Script uses the public anon JWT). Security is enforced by the shared_secret check against vault entry APPSCRIPT_INGEST_SECRET (48 base64 chars). Advisor lints 0028_anon_security_definer_function_executable + 0029_authenticated_security_definer_function_executable are expected and documented as intentional. UPSERTs the JSONB array into tickpick_orders by tp_order_id. Returns (inserted, updated, skipped). |
| `tickpick_orders_process()` | TABLE(processed integer, orders_persisted integer) |  |
| `tickpick_orders_queue(p_pages integer)` | integer |  |
| `tokenize_chat_text(p_text text)` | TABLE(term text) |  |
| `tournament_category_pending_sweep()` | integer |  |
| `tournament_match_score(p_tevo text, p_espn text)` | integer |  |
| `tournament_name_tokens(p_name text)` | text[] |  |
| `tournament_pull_process()` | TABLE(processed integer, persisted integer, filtered_non_na integer) |  |
| `tournament_pull_queue(p_max_pages integer)` | integer |  |
| `tournament_search_pending_sweep()` | integer |  |
| `trg_event_alerts_broadcast()` | trigger |  |
| `trg_set_updated_at()` | trigger |  |
| `trg_sg_sales_populate_tevo_event_id()` | trigger |  |
| `trg_sgec_to_seatgeek_event_xref()` | trigger |  |
| `trg_sync_cei__event_xref()` | trigger |  |
| `trg_sync_cei__perf_espn_team_xref()` | trigger |  |
| `trg_sync_cei__performer_external_ids()` | trigger |  |
| `trg_sync_cei__sd_event_xref()` | trigger |  |
| `trg_sync_cei__sd_venue_xref()` | trigger |  |
| `trg_sync_cei__sg_event_xref()` | trigger |  |
| `trg_sync_cei__sg_venue_xref()` | trigger |  |
| `trg_sync_cei__venue_assets_espn()` | trigger |  |
| `trg_sync_pei__sd_perf_xref()` | trigger |  |
| `trg_sync_pei__sg_perf_xref()` | trigger |  |
| `trg_sync_pei__wikipedia()` | trigger |  |
| `trg_truncate_resync__event_xref()` | trigger |  |
| `trg_truncate_resync__pei()` | trigger |  |
| `trg_truncate_resync__perf_espn_team_xref()` | trigger |  |
| `trg_truncate_resync__sd_event_xref()` | trigger |  |
| `trg_truncate_resync__sd_venue_xref()` | trigger |  |
| `trg_truncate_resync__sg_event_xref()` | trigger |  |
| `trg_truncate_resync__sg_venue_xref()` | trigger |  |
| `ugc_from_url(p_url text)` | text |  |
| `ugc_kind(p_ugc text)` | text |  |
| `ugc_state(p_ugc text)` | text |  |
| `unaccent(regdictionary, text)` | text |  |
| `unaccent(text)` | text |  |
| `unaccent_init(internal)` | internal |  |
| `unaccent_lexize(internal, internal, internal, internal)` | internal |  |
| `upsert_app_secret(p_name text, p_value text)` | jsonb |  |
| `upsert_espn_event_snapshot(p_event_id text, p_league text, p_hash text, p_payload jsonb)` | TABLE(action text, snap_id bigint) | Change-only insert. Returns action=inserted|unchanged. Used by espn-collect v3+. |
| `upsert_espn_injury(p_team_id text, p_athlete_id text, p_hash text, p_payload jsonb)` | TABLE(action text, snap_id bigint) | Change-only insert per athlete. Used by espn-collect v3+. |
| `upsert_espn_team_snapshot(p_team_id text, p_league text, p_hash text, p_payload jsonb)` | TABLE(action text, snap_id bigint) | Change-only insert. Returns action=inserted|unchanged. Used by espn-collect v3+. |
| `venue_geocode_process()` | TABLE(processed integer, hits integer, misses integer) |  |
| `venue_geocode_queue(p_limit integer)` | integer |  |
| `venue_metric_value(p_venue_id bigint, p_metric_key text, p_at timestamp with time zone)` | numeric |  |
| `venue_norm(p_name text)` | text |  |
| `venue_pull_queue(p_max_pages integer)` | integer |  |
| `venue_section_token(p_section text)` | text |  |
| `venue_section_token_base(p_section text)` | text |  |
| `vivid_orders_process()` | TABLE(processed integer, orders_persisted integer, http_failures integer) |  |
| `vivid_orders_queue(p_status text)` | integer |  |
| `vsm_listing_token(p_section text, p_platform text)` | text | Platform-aware listing-side seat token. evo -> venue_section_token; sg/tp/vd/sh additionally peel a leading 1-4 letter prefix ("BAL316"->"316"). |
| `vsm_listing_token_base(p_section text, p_platform text)` | text |  |
| `weather_forecast_process()` | TABLE(processed integer, rows_persisted integer) |  |
| `weather_forecast_queue(p_limit integer)` | integer |  |
| `weather_historical_backfill(p_start date, p_end date, p_limit integer)` | integer |  |
| `weather_historical_backfill_outdoor(p_start date, p_end date, p_limit integer)` | integer |  |
| `weather_historical_process()` | TABLE(processed integer, rows_persisted integer) |  |
| `weather_historical_retry_throttled(p_limit integer)` | integer |  |
| `wiki_pending_sweep()` | integer |  |
| `wmo_to_summary(p_code integer)` | text |  |
| `word_similarity(text, text)` | real |  |
| `word_similarity_commutator_op(text, text)` | boolean |  |
| `word_similarity_dist_commutator_op(text, text)` | real |  |
| `word_similarity_dist_op(text, text)` | real |  |
| `word_similarity_op(text, text)` | boolean |  |

---

## Tables (212)

| Table | Size | Comment |
|---|---|---|
| `alert_mail` | 88 kB |  |
| `alert_metric_catalog` | 32 kB |  |
| `aq_event_map` | 8088 kB | Operator-curated cross-source event map from AQ/Automatiq. aq_short_event_id (7-char) is the canonical primary key; every order/listing table FKs back to this. Imported 2026-05-14 from kjUntitled spreadsheet.xlsx. 5,921 rows with non-null short IDs (238 unclassified rows dropped). |
| `aq_performer_map` | 328 kB |  |
| `aq_tevo_search_attempts` | 592 kB | Per-hub-row attempt ledger for the AQ->TEvo cold-search bridge (aq-to-tevo-search-bridge edge fn). Keyed on aq_event_map.id. Mirrors sg_tevo_search_attempts. no_results/low_score rows are retried after the backoff window; matched rows are terminal. |
| `aq_venue_map` | 336 kB |  |
| `axs_event_requests` | 120 kB |  |
| `axs_event_snapshots` | 1876 MB | AXS event pulls (primary + AXS-Marketplace resale), one row per fetch. raw=full document; metrics derived by axs_client.normalize(). tevo_venue_id pegged from axs_venues; tevo_event_id AQ-derived. Source is read-only. |
| `axs_events` | 960 kB | AXS events to ingest (from AXS_RESALE workbook col D). Drained into axs_event_snapshots via /fetch?platform=axs. Read-only source. |
| `axs_performers` | 32 kB |  |
| `axs_probe` | 368 kB |  |
| `axs_seat_snapshots` | 722 MB | Per-seat normalization of an AXS pull (FK axs_event_snapshots / axs_section_snapshots). One row per veritix offers[].items[] seat; raw_item retains the full source object. Read-only source. |
| `axs_section_snapshots` | 3776 kB | Per-section normalization of an AXS pull (FK axs_event_snapshots). AXS analog of per-listing snapshot rows. |
| `axs_venues` | 1680 kB | AXS.com primary-ticketer venue list (operator scrape 2026-06-09). Static reference; tevo_venue_id is an exact-normalized link to v_canonical_venue/cross_source_venue_map where one exists, NULL = unmapped (review later). AXS is not a resale source. |
| `bot_chat` | 1664 kB |  |
| `bot_messages` | 128 kB |  |
| `bot_users` | 32 kB |  |
| `bridge_event_xref` | 32 kB |  |
| `broker_xref` | 32 kB |  |
| `canonical_external_ids` | 6016 kB |  |
| `chat_aliases` | 1160 kB |  |
| `chat_audit_findings` | 96 kB | Ground-truth audit of bot no-results claims. For each bot reply that claimed nothing was available, we replay the filters against listings_snapshots at the response time and verify. |
| `chat_corpus` | 136 kB | Training-grade rollup of paired (user, bot) turns from bot_messages. Future fine-tune dataset for the Groq/OSS-LLM swap. |
| `chat_glossary_known` | 32 kB |  |
| `chat_rate_limits` | 64 kB |  |
| `chat_stopwords` | 32 kB |  |
| `chat_term_freq_in` | 80 kB |  |
| `chat_term_freq_out` | 240 kB |  |
| `chat_term_frequency` | 112 kB | N-gram word pool from retail chat user inputs. Drives chat_glossary_candidates discovery. |
| `collector_cadence` | 32 kB |  |
| `concierge_events` | 288 kB | Storefront concierge rail rollup: upcoming owned events with premium (>= $500) top-band seats, from broker_listings (EVO only). Maintained by refresh_concierge_events(). D3 2026-06-16. |
| `cron_gate_decisions` | 61 MB |  |
| `cron_pause_state_20260514` | 64 kB |  |
| `cron_policy` | 88 kB |  |
| `cross_source_venue_map` | 296 kB |  |
| `data_source_field_map` | 88 kB |  |
| `data_sources` | 32 kB |  |
| `discovery_gap_alerts` | 1744 kB | Active market coverage and opportunity gaps from evo_sg_discovery_gaps(). gap_types: sg_no_evo | td_sh/gt/vd_no_evo | td_sh_no_gt | td_gt/vd_premium | evo_no_sg | value_gap_large | fill_rate_spike |
| `entity_xref_conflicts` | 24 kB |  |
| `entity_xref_overrides` | 16 kB |  |
| `espn_asset_crawl_state` | 64 kB |  |
| `espn_athlete_team_history` | 561 MB |  |
| `espn_athletes` | 232 MB |  |
| `espn_event_date_lookup` | 2032 kB |  |
| `espn_event_snapshots` | 19 MB |  |
| `espn_injuries_snapshots` | 627 MB |  |
| `espn_news` | 4320 kB |  |
| `espn_runs` | 8176 kB |  |
| `espn_scoreboard_pending` | 104 kB |  |
| `espn_team_snapshots` | 952 kB |  |
| `espn_teams_canonical` | 80 kB | Hard-coded ESPN team list (152 teams across NBA/NFL/MLB/NHL/WNBA). Source: ESPN site.api /teams endpoint, captured 2026-05-10. Refresh when team relocations / expansion happen. |
| `espn_tournament_events` | 4568 kB |  |
| `espn_tournament_pending` | 48 kB |  |
| `event_alerts` | 295 MB |  |
| `event_competitors_snapshot` | 1104 kB |  |
| `event_listing_snapshot_daily` | 95 MB | 3 daily point-in-time metric snapshots per event (morning/midday/evening ET). EVO source: event_metrics. SG source: seatgeek_event_metrics. Kept 1 year. Complements event_metrics (7-day TTL raw data) for long-term trend analysis. |
| `event_match_attempts` | 88 kB | Audit log of every event-matching attempt. Lets the day-trader trace why an event landed in v_unmatched_events and what was tried. |
| `event_metrics` | 172 MB |  |
| `event_movers_agg` | 2184 kB |  |
| `event_movers_index` | 640 kB | Top-25 movers per (source × window_days × category). window_days = event horizon (events in next N days). Signal = half-window SMA vs prior-half SMA. Updated 3x/day by compute_movers_index_post_snapshot cron (7:35/13:35/19:35 UTC). |
| `event_movers_index_history` | 1616 kB | Composition changes for event_movers_index: enter/exit/rank_change. When did an event join the index and at what price? |
| `event_pulls` | 96 kB |  |
| `event_section_row_snapshots` | 3931 MB |  |
| `event_sentiment` | 19 MB |  |
| `event_watchlist` | 120 kB |  |
| `event_xref` | 3704 kB | TEvo event -> ESPN event mapping. Populated lazily by the espn Edge Function when an event_id is first looked up. |
| `event_xref_cleanup_archive_20260606` | 120 kB |  |
| `events` | 14 MB |  |
| `evo_event_backfill_pending` | 80 kB |  |
| `evo_listings_poll_state` | 7312 kB |  |
| `evo_only_patterns` | 32 kB | Allowlist driving tag_evo_only_events(): performer/venue ILIKE patterns whose matching TEvo events are intentionally EVO-only (no cross-source twin exists). |
| `evo_order_items` | 8208 kB |  |
| `evo_orders` | 15 MB |  |
| `evo_orders_pending` | 344 kB |  |
| `exos_discount_codes` | 24 kB |  |
| `exos_event_checkins` | 64 kB |  |
| `exos_events` | 96 kB |  |
| `exos_mail` | 64 kB |  |
| `exos_org_follows` | 16 kB |  |
| `exos_org_invites` | 32 kB |  |
| `exos_org_memberships` | 80 kB |  |
| `exos_org_secrets` | 16 kB |  |
| `exos_orgs` | 48 kB |  |
| `exos_profiles` | 80 kB |  |
| `exos_scan_rejects` | 48 kB |  |
| `exos_ticket_tiers` | 48 kB |  |
| `exos_tickets` | 152 kB |  |
| `exos_transfers` | 96 kB |  |
| `fred_pending` | 48 kB |  |
| `general_subreddits` | 32 kB | Leaguewide / cross-team subreddits not tied to a specific performer. Used for general-sentiment pulls. |
| `health_check_history` | 3016 kB |  |
| `health_web_probe` | 520 kB |  |
| `health_web_targets` | 32 kB |  |
| `holidays` | 144 kB |  |
| `important_x_accounts` | 264 kB | Roster of X.com handles by category (insiders, beat reporters, teams, leagues, Broadway shows/producers/reporters, concert venues/promoters/artists). Phase 1 cannot pull X directly. This table is INFORMATIONAL CONTEXT for AI/RAG consumers: when the chatbot sees a Reddit post quoting a known insider, it can recognize the source. Same intent as performer_wikipedia: prompt context, not SQL analytics. |
| `integration_policy` | 32 kB |  |
| `leads` | 96 kB | Reserve-via-rep submissions. HARD RESTRICT (rule 15): no auto-purchase. |
| `listing_xref` | 611 MB |  |
| `listings_snapshots` | 48 GB |  |
| `macro_indicators` | 120 kB |  |
| `macro_series_config` | 32 kB |  |
| `major_event_calendar` | 64 kB | Curated calendar of major non-team events (F1/NASCAR/Tennis/Golf majors). Anchors venue+date filtering for events that don't have a TEvo team performer. |
| `matchup_xref` | 184 kB |  |
| `mlb_branded_series` | 32 kB |  |
| `news_keywords` | 32 kB | Keywords that signal a Reddit post is "important news" worth surfacing to the chatbot. Per-category weights so a Broadway sub does not match sports keywords accidentally. |
| `nws_alert_pending` | 6512 kB |  |
| `nws_alert_references` | 5592 kB |  |
| `nws_alert_zones` | 26 MB |  |
| `nws_alerts` | 250 MB |  |
| `order_fee_schedule` | 32 kB |  |
| `order_status_xref` | 64 kB |  |
| `performer_baselines` | 32 kB |  |
| `performer_crawl_state` | 16 kB |  |
| `performer_espn_team_xref` | 96 kB | Maps TEvo performer_id (team identity) to ESPN team_id per league. Built from name match against espn_teams_canonical with variant aliases for known edge cases (LA Clippers, Athletics). |
| `performer_external_ids` | 752 kB | Maps TEvo performer_id to identifiers used by external feeds (ESPN, Odds API, SportsDataIO). Required join layer for ESPN/odds/standings/player-stats integration. |
| `performer_home_venues` | 120 kB | Maps a performer (sports team) to its home venue. Lets the chatbot interpret "X at home" / "X home game" → filter events to venue_id. Seeded from TEvo /v9/performers. |
| `performer_metadata` | 4096 kB | Cache of TEvo /v9/performers/{id}. Captures genre + top_category + popularity for every performer encountered. Powers WHAT/WHY chatbot slots. |
| `performer_metrics_daily` | 13 MB |  |
| `performer_subreddits` | 88 kB |  |
| `performer_wiki_pending` | 128 kB |  |
| `performer_wikipedia` | 912 kB | Wikipedia summary enrichment per TEvo performer (title, extract, image_url, wiki_url). Intended consumer: AI/RAG connectors that want plain-English context about a performer (e.g. "who is this team / artist"). NOT intended as a SQL analytics surface — buzz/trend signals live in price/order deltas. See docs/wikipedia-usage-2026-05-09.md. |
| `performer_zone_rules` | 872 kB |  |
| `performer_zones` | 168 kB |  |
| `pull_rate_limits` | 32 kB |  |
| `reddit_pending` | 280 kB |  |
| `reddit_posts` | 4720 kB |  |
| `runs` | 448 kB |  |
| `school_break_windows` | 88 kB |  |
| `seatdata_event_stats` | 32 kB |  |
| `seatdata_event_xref` | 128 kB |  |
| `seatdata_listings_snapshots` | 32 kB |  |
| `seatdata_performer_xref` | 32 kB |  |
| `seatdata_pull_budget` | 64 kB |  |
| `seatdata_pull_log` | 408 kB |  |
| `seatdata_sales_snapshots` | 32 MB |  |
| `seatdata_search_attempts` | 104 kB |  |
| `seatdata_section_xref` | 24 kB |  |
| `seatdata_venue_xref` | 32 kB |  |
| `seatdata_zone_xref` | 24 kB |  |
| `seatgeek_event_metrics` | 77 MB | Per-event SG-side aggregates. A1 2026-05-18: dropped legacy cost_* columns (SellerDirect-only populator retired). Active columns: listings_all_* (PR #204), listings_owned_* (PR #204), sold_* (PR #161), orders_* (legacy), edelivery_share/instant_share/fill_rate/unique_sections/unique_rows (legacy from compute_seatgeek_event_metrics path — now also inert post-drop). |
| `seatgeek_event_xref` | 1200 kB |  |
| `seatgeek_historic_sales` | 496 kB | Structured historic SG sales — parsed performers + season + section. Materialized from seatgeek_orders. Re-runnable via populate_seatgeek_historic_sales(). |
| `seatgeek_listings_snapshots` | 13 GB |  |
| `seatgeek_order_tickets` | 24 kB |  |
| `seatgeek_orders` | 83 MB |  |
| `seatgeek_orders_resolved` | 248 kB |  |
| `seatgeek_performer_xref` | 192 kB |  |
| `seatgeek_pull_log` | 32 kB |  |
| `seatgeek_sales_snapshots` | 7512 MB |  |
| `seatgeek_seller_listings` | 5320 kB |  |
| `seatgeek_seller_pull_log` | 24 kB |  |
| `seatgeek_venue_xref` | 104 kB |  |
| `seatmap_manifest` | 2864 kB | Cached TEvo seat-map manifests (section keys) per venue/config, fetched by the seatmap-manifest-sync edge fn. has_map = real interactive-map availability (replaces fanvenues_key proxy). D0, mig 20260603160000. |
| `section_metrics` | 8151 MB |  |
| `settings` | 32 kB |  |
| `sg_broker_pending` | 51 MB |  |
| `sg_event_backfill_pending` | 64 kB |  |
| `sg_event_match_pending` | 32 kB |  |
| `sg_event_priority_state` | 502 MB |  |
| `sg_events_canonical` | 34 MB | One row per SG event we have ANY data on (seller_listings, /v2 pull, or just metadata). tevo_event_id NULL = unmatched. Auto-matcher iterates this table to fill links over time. |
| `sg_league_priority_config` | 32 kB |  |
| `sg_listings_pending` | 112 kB |  |
| `sg_market_chart` | 3544 kB |  |
| `sg_priority_policy` | 32 kB |  |
| `sg_seller_pending` | 2792 kB |  |
| `sg_tevo_search_attempts` | 960 kB | Tracks TEvo search-bridge attempts per sg_event_id to avoid burning API on repeat queries. Cleared automatically when sg_event matches. |
| `share_links` | 32 kB | Revocable storefront share links — /s/{id} resolves to one event with saved filters. |
| `snapshots` | 88 kB |  |
| `sporting_rivalries` | 160 kB |  |
| `taxonomy_xref` | 96 kB |  |
| `td_discover_targets` | 168 kB |  |
| `td_discovered_events` | 40 kB |  |
| `td_gt_performers` | 48 kB |  |
| `td_match_queue` | 160 kB |  |
| `td_match_results` | 96 kB |  |
| `td_poll_failures` | 528 kB |  |
| `td_poll_policy` | 32 kB |  |
| `td_pull_queue` | 2456 kB |  |
| `td_sg_performers` | 48 kB | Allowlist of high-value unmapped TEvo performers to discover on SeatGeek via the TicketsData /events?platform=seatgeek search. Drives td_sg_discover(). Budget-gated. |
| `td_tm_performers` | 80 kB |  |
| `td_tp_performers` | 80 kB |  |
| `tevo_blindspot_discovery_attempts` | 80 kB | Audit log for tevo_blindspot_discovery_daily cron firings. |
| `tevo_ticket_groups_cache` | 264 kB | Short-TTL cache of /v9/ticket_groups responses. Used by chat fn to deduplicate redundant TEvo fetches across get_event_zones + find_listings + find_better_seats. |
| `ticketsdata_credit_usage` | 952 kB |  |
| `ticketsdata_event_xref` | 2216 kB |  |
| `ticketsdata_listings_snapshots` | 7584 MB |  |
| `tickpick_orders` | 159 MB |  |
| `tickpick_orders_pending` | 48 kB |  |
| `tournament_categories` | 32 kB |  |
| `tournament_category_pending` | 104 kB |  |
| `tournament_search_pending` | 48 kB |  |
| `tournament_search_queries` | 32 kB |  |
| `user_alerts` | 64 kB |  |
| `venue_assets` | 320 kB |  |
| `venue_baselines` | 32 kB |  |
| `venue_crawl_state` | 144 kB |  |
| `venue_geocode_pending` | 88 kB |  |
| `venue_metrics_daily` | 2336 kB |  |
| `venue_nws_points_pending` | 88 kB |  |
| `venue_pulls` | 32 kB |  |
| `venue_section_map` | 1624 kB | Cross-platform seat-map crosswalk: for each (venue, platform, raw section string) the matched seatmap_manifest polygon key + method/confidence. Written only by build_venue_section_map() (SECURITY DEFINER). EVO populated 2026-06-08; sg/tp/vd/sh extend later. |
| `vivid_orders` | 179 MB |  |
| `vivid_orders_pending` | 240 kB |  |
| `watch_sources` | 1968 kB |  |
| `watchlist` | 144 kB |  |
| `wc_price_daily` | 200 kB |  |
| `weather_forecast_pending` | 2560 kB |  |
| `weather_observations` | 233 MB | Open-Meteo weather observations. is_forecast=true for ≤16-day forecasts; =false for historical archive (ERA5 reanalysis, lags real-time by ~5 days). |
| `why_signals` | 96 kB | Contextual demand-signal store. Sources: weather (NOAA/OWM), social (Spotify/Reddit/YouTube/Bandsintown), news (RSS), holidays. Per-event/performer/city/global scope. Used to enrich WHY bucket + boost chip rotation. |
| `world_cup_2026` | 152 kB | Canonical 2026 FIFA World Cup match series (one row per match). Static tournament structure + EVO/TEvo linkage + ownership snapshot. Populated/maintained by refresh_world_cup_2026() from sg_events_canonical + events + latest_event_metrics. D3 2026-06-16. |
| `zone_metrics` | 45 MB | Per-zone aggregates captured at same snapshot tick as event_metrics. zone_source: curated (performer_zones), fallback (derive_zone_fallback), unmapped. |
| `zone_rules` | 48 kB |  |

---

## Views (178)

| View | Comment |
|---|---|
| `_v_d0_event_index` | D0 Phase 2a canonical entry view. One row per upcoming/recent event with all bridge IDs (sg/tevo/aq/espn) + venue context. Freshness signals fetched on-demand because seatgeek_event_xref.last_*_at and sg_events_canonical.has_v2_listings_pulled are dead columns (0% population). |
| `broker_event_metrics` | PRODUCT BOUNDARY: broker terminal. Full market metrics. |
| `broker_event_sections` | PRODUCT BOUNDARY: broker terminal. Full section metrics including non-owned. |
| `broker_event_zones` | PRODUCT BOUNDARY: broker terminal. Full zone metrics including non-owned. |
| `broker_listings` | PRODUCT BOUNDARY: broker terminal. Full inventory across all brokerages. |
| `chat_audit_lies` |  |
| `chat_audit_recurring_lies` |  |
| `chat_corpus_training` |  |
| `chat_failures` |  |
| `chat_glossary_candidates` | High-frequency phrasing the bot does NOT yet handle in its system prompt glossary. Review periodically and add to chat_glossary_known + system prompt. |
| `cross_source_coverage` |  |
| `cross_source_event_audit` |  |
| `data_source_field_map_audit` | Coverage report — lists every table that should be in data_source_field_map. has_field_map_rows = false means drift: someone added a table without documenting it in the cross-walk. Run this in CI / nightly checks. |
| `entity_event_map` |  |
| `entity_performer_map` |  |
| `entity_venue_map` |  |
| `espn_event_snapshot_latest` |  |
| `espn_injury_snapshot_latest` | Latest injury snapshot per (league, team, athlete). A1 2026-05-18 (mig 20260519180002): added espn_league to DISTINCT ON key + output — defense-in-depth against cross-league espn_team_id collisions. |
| `espn_team_snapshot_latest` |  |
| `event_lifecycle` | Bulk lifecycle classification across all events. Filter is_active=true for live surfaces (movers, league grid, portfolio aggregates). 18% of future events are non-active as of 2026-05-09. |
| `event_series` |  |
| `event_velocity` |  |
| `events_with_home_flag` | events table joined with performer_home_venues. is_home_game=true when the event venue matches the performer home venue. |
| `evo_orders_by_event` |  |
| `exos_public_events` | Public storefront projection: published events only. SECURITY DEFINER by design (base tables are RLS-locked to staff). Advisor 0010 ERROR accepted — see migration 20260601120500. |
| `exos_public_orgs` | Public storefront projection: org public pages. SECURITY DEFINER by design (base tables are RLS-locked to staff). Advisor 0010 ERROR accepted — see migration 20260601120500. |
| `exos_public_tiers` | Public storefront projection: public tiers of published events. SECURITY DEFINER by design (base tables are RLS-locked to staff). Advisor 0010 ERROR accepted — see migration 20260601120500. |
| `latest_snapshots` |  |
| `latest_zone_metrics` |  |
| `matchup_history` |  |
| `order_status_coverage` |  |
| `our_orders` | OUR own sales rolled up across TEvo + SG sellerdirect. Distinct from unified_orders which mixes in SeatData (market observations of sales we did NOT make). Day-trader use: actual book / cash flow rollup. |
| `our_orders_by_event` | Per-event rollup of our_orders. Powers "our book on this game" widget. Distinct from unified_orders_by_event which includes SeatData market obs. |
| `our_orders_by_event_with_net` |  |
| `our_orders_with_net` |  |
| `retail_event_metrics` | PRODUCT BOUNDARY: retail chatbot. Customer-facing event roll-up (no wholesale, no broker fields). |
| `retail_event_sections` | PRODUCT BOUNDARY: retail chatbot. Per-section availability + price band, S4K-owned only. |
| `retail_event_zones` | PRODUCT BOUNDARY: retail chatbot. Per-zone availability + price band, S4K-owned only. |
| `retail_events` | PRODUCT BOUNDARY: retail chatbot. Events with at least one S4K-owned listing. |
| `retail_listings` | PRODUCT BOUNDARY: retail chatbot. S4K-owned non-ancillary listings, latest snapshot, broker columns stripped. |
| `sd_sales_normalized` |  |
| `seatdata_event_latest` |  |
| `seatgeek_categorized_listings` |  |
| `seatgeek_event_latest` | A1 2026-05-19: sales_count dedup via DISTINCT ON (sg_sale_id). Was reporting 11-23x. |
| `seatgeek_orders_by_event` |  |
| `sg_canonical_match_view` | Single-row-per-SG-event view with TEvo match details + status bucket. match_status = matched | pending_match | past_unmatched. |
| `team_xref` | COMPAT VIEW (2026-05-07) — backs cowork RPCs that still reference team_xref. Source of truth is performer_external_ids where source='espn'. Kept until all RPCs migrate. |
| `unified_listings` | All listing sources in a single queryable surface. source_key values: tevo, sg_broker, sg_seller, seatdata, td_sh, td_vd, td_gt. TD arm added 2026-05-27 (20260527140000). Filter is_ancillary=false to exclude parking. |
| `unified_orders` | A1 2026-05-19: seatgeek_sales source dedup via DISTINCT ON (sg_sale_id). Was emitting 15x rows. |
| `unified_orders_by_event` |  |
| `v_aq_match_quality` | A1 2026-05-19: seatgeek_sales_snapshots row dedups on sg_sale_id. Was 15x. |
| `v_arbitrage_opportunities` |  |
| `v_axs_events_classified` |  |
| `v_axs_listings` | AXS box-office inventory in the EVO listing standard (section/row/quantity/retail_price/format/splits/type/wheelchair, keyed on tevo_event_id), one row per consecutive-seat block (v_axs_seat_groups). Adds AXS-only seat_from/seat_to/seat_numbers. Read-only. |
| `v_axs_seat_groups` | AXS DATA RULE: consecutive seats (same section+row+price+seat_type+src, adjacent seat numbers) collapsed into one "N together" block via gaps-and-islands. qty = block size, seat_from/seat_to = range, seats = the member numbers. Non-numeric labels stay qty-1. Source for the marketplace-style AXS listing view. |
| `v_axs_venues_mapped` |  |
| `v_axs_venues_unmapped` | AXS.com venues not exact-matched to a canonical venue (review-later list). Source: public.axs_venues. |
| `v_bot_chat_unresolved` |  |
| `v_broadway_runs` |  |
| `v_broker_configurations` |  |
| `v_canonical_coverage` |  |
| `v_canonical_coverage_v2` |  |
| `v_canonical_drift` |  |
| `v_canonical_event` |  |
| `v_canonical_performer` |  |
| `v_canonical_venue` | Single-row-per-venue view. Joins TEvo venue dim + SeatData std venue + SG venue (via name match) + venue_assets (capacity / images / ESPN). |
| `v_competing_events` | ±24 HOURS competing events within 20 miles. Captures cross-midnight pairs. |
| `v_cron_health` | Last-24h health rollup per active cron job. SECURITY DEFINER so anon can read aggregates without needing direct grants on the cron schema. Dashboard fetchCronLive() consumes this. Failing jobs sort to the top in the UI by lowest pct_ok. |
| `v_dashboard_coverage` | Single-row coverage scoreboard for the data quality dashboard. All five metrics computed against upcoming sports games (next 30d for most, 16d for weather since that is Open-Meteo's forecast horizon). Replaces the proto's broken row-counting approach that produced > 100% values. |
| `v_dashboard_freshness` | Single-row-per-source freshness signal. For sources whose endpoints can return empty payloads (SG seller orders), uses GREATEST(data_write, successful_poll_via_pending_table_status_200) so the dashboard does not show a false-stale signal when the cron is healthy and the API just has no rows to send. Replaces 8 client round-trips with 1 SELECT. |
| `v_espn_game_results` | One row per finalized ESPN game, joined to TEvo events for venue context. DISTINCT ON espn_event_id ORDER BY captured_at DESC = latest snapshot only (handles multiple in-progress captures per game). |
| `v_espn_injuries_current` | Latest injury status per athlete across all leagues. Same DISTINCT ON pattern as v_espn_team_state — works correctly even with broken is_baseline detection on non-MLB/NHL leagues. |
| `v_espn_live_result_price_impact` | Per tracked team in a current/recent (12h) game: its future events + latest price snapshot. For watching game result vs future-date price impact. |
| `v_espn_team_state` | Current standings/record/streak per ESPN team. DISTINCT ON team_id ORDER BY captured_at DESC sidesteps the is_baseline bug (broken for NBA/NFL/MLS/WNBA/WC) by always returning latest snapshot. |
| `v_event_active_weather_alerts` | Per-event currently-active NWS alerts. Joins on either ugc_county_code OR ugc_forecast_zone since alerts use one or the other. |
| `v_event_base` |  |
| `v_event_betting_odds_latest` |  |
| `v_event_calendar_context` | Per-event calendar overlay. State + city extracted from venue_location. holidays_today / holidays_nearby / school_breaks_active each return ALL matching rows (national + state + city) ordered most-precise-first. Each row carries precision = "national" | "state" | "city" so the UI can render "Boston Marathon (Patriots' Day)" alongside "US Federal Holiday: Patriots' Day" without dedup logic in app code. Replaces the country-only view from migration 540000. |
| `v_event_competing_events` |  |
| `v_event_competitors` |  |
| `v_event_data_freshness` |  |
| `v_event_espn_injuries` |  |
| `v_event_espn_news` |  |
| `v_event_espn_state` |  |
| `v_event_evo_orders` |  |
| `v_event_full` | Kitchen-sink event view — one query gets every cross-source ID, performer with Wikipedia, venue, plus per-source pricing summary. |
| `v_event_full_sports` | Full event row + ESPN team-state + injury counts + news counts + listings medians. A1 2026-05-18 (mig 20260519180002): league-scoped on injury/news subqueries and v_espn_team_state joins. espn_league exposed as a top-level column. |
| `v_event_full_v2` |  |
| `v_event_holidays` |  |
| `v_event_home_away` | Identifies home + away performer for each event by matching performer_home_venues to events.venue_id. Falls back to events.primary_performer_id when no home match found. Adds days_to_event and primary_is_home convenience columns. |
| `v_event_injuries` | Per-event ESPN injury overlay. Joins events -> event_xref -> espn_event_snapshots -> espn_injuries_snapshots on (espn_team_id, espn_league). Dedups by (team, league, athlete_name) since ESPN sometimes emits multiple athlete_ids over time for the same player (negative stub IDs, NULLs, then canonical positives). |
| `v_event_line_movement` |  |
| `v_event_listing_trends` | Trend analysis over event_listing_snapshot_daily (3 slots/day, 1-year retention). WoW delta = LAG(3) = same slot 1 week earlier. DoD delta = LAG(1) = prior snapshot. 21-slot rolling avg = 7 calendar days smoothed. evo_owned_vs_market_pct: 100=at market, <100=below, >100=above. sg_vs_evo_spread: positive means SG market is more expensive than EVO. evo_owned_7d_velocity: +ve=accumulating tickets, -ve=selling down. |
| `v_event_major_calendar` |  |
| `v_event_mlb_branded_series` |  |
| `v_event_nws_alerts` |  |
| `v_event_overlay_summary` |  |
| `v_event_price_arbitrage` | A1 2026-05-18 — 3-way price comparison: TEvo retail vs SG owned (broker-held real inv) vs SG all-listings (full firehose incl spec). Was reading cost_* legacy cols pre-PR #204; migrated to listings_owned_* and listings_all_* (PR-4a). |
| `v_event_reddit` |  |
| `v_event_sales_combined` |  |
| `v_event_sales_metrics_filtered` |  |
| `v_event_sales_velocity` |  |
| `v_event_school_breaks` |  |
| `v_event_seating_chart` |  |
| `v_event_sporting_rivalries` |  |
| `v_event_team_standings` |  |
| `v_event_tournament_context` |  |
| `v_event_velocity_windows` |  |
| `v_event_weather` |  |
| `v_event_weather_with_fallback` |  |
| `v_event_why_context` |  |
| `v_event_xref_collisions` | Flags ESPN event_ids xref'd to multiple TEvo team-game events that are NOT same-game promo dupes (e.g. "Yankees at Orioles" + "Yankees at Orioles (Bobblehead Giveaway)"). Excludes tournament_token_overlap matches. |
| `v_event_xref_proposed` | Strict (home_team_id, away_team_id) matcher result for each TEvo game. Compare state column to current xref to find wrong/missing matches. Used by the bulk-cleanup migration to fix the broken edge-function output. |
| `v_events_5w` | 5W projection of events: what (event_type), when (occurs_at_local), who (performer_*), where (venue_*). Powers v28 chatbot discovery + structured search. |
| `v_events_pullable` |  |
| `v_listing_zone_auto` | Auto-assigns curated zone to each listing via performer_zone_rules. Falls back to numeric_fallback when no curated zone exists for the (home_performer, venue) pair. Used by zone-aware pricing queries. |
| `v_macro_indicators_health` |  |
| `v_macro_indicators_latest` |  |
| `v_market_listings_by_event` |  |
| `v_mlb_game_series` |  |
| `v_one_to_one_health` |  |
| `v_open_alerts` |  |
| `v_orphan_seatdata_data` |  |
| `v_orphan_seatgeek_data` | A1 2026-05-19: sales kind dedup via DISTINCT ON (sg_sale_id). row_count was 11-23x. |
| `v_outgoing_terms_without_incoming_alias` | Round-trip integrity: tokens bot says that no incoming alias resolves to. Add aliases to close the loop. |
| `v_performer_news_sources` | Per-performer roster of all known news sources (X handles + subreddits). AI-RAG consumer reads this to know "who covers this team" before composing a prompt. |
| `v_performer_reddit_pulse` |  |
| `v_performer_residencies` |  |
| `v_performer_tours` |  |
| `v_pg_net_queue_health` |  |
| `v_pricing_cross_source` | Section-level pricing JOIN across all 4 pricing sources. FULL OUTER so a section visible on one source but not others still appears. sg_vs_tevo_pct + sd_sold_vs_tevo_listed_pct give arbitrage signals. |
| `v_reddit_important_recent` | 48h window of Reddit posts that hit at least one news_keywords entry. |
| `v_returning_entities` | Performers + venues with past activity → gap → upcoming events. Sources: TEvo perf+venue, SG venue. v2 will add SG performer. |
| `v_rivalry_events` |  |
| `v_s4k_inventoried_events` | CANONICAL filter for retail surfaces: events S4K actually has tickets for (latest snapshot in last 24h). Every chat/web RPC must join through this to hide events we cannot sell. |
| `v_seatgeek_listings_classified` |  |
| `v_section_to_curated_zone` | Per-event (section_range, zone) listing. Use to enrich v_pricing_cross_source rows with their curated zone bucket: JOIN ON section_in_range(v.section, x.section_from, x.section_to). |
| `v_sg_blindspot_evo_tracking` | SG-selling/we're-not-in (tier TRACK_BLINDSPOT, future, owned=0) events with SG realized-sales demand alongside the EVO/TEvo live listings book from latest_event_metrics. Ranked by SG sold gross. Read via get_sg_blindspot_evo_tracking(). |
| `v_sg_blindspot_movers` |  |
| `v_sg_broker_429_health` | A1 2026-05-19: rolling 24h hourly pct_429 monitor for SG broker pipeline. Reads sg_broker_pending.rows_persisted sentinel (-429 set by 429-aware processors per PR #212). |
| `v_sg_broker_429_starved_events` | A1 2026-05-19: events that have been 429-rate-limited 3+ times in last 24h with no more recent success. Indicates per-event chronic starvation (vs systemic). Surfaces hot spots the broader pct_429 rollup might miss. |
| `v_sg_broker_sales_by_event` | Per-event rollup of SG broker firehose sales. Mirrors v_sg_sales_by_event shape (sales_count, tickets_sold, gross_estimate, min/median/max sale_price, distinct_sections, sections, latest_sale_at). Aggregates over the deduplicated set (DISTINCT ON sg_sale_id, latest by pulled_at). Use for FE event-index "heat" signals. |
| `v_sg_broker_sales_by_section` | Section-grain SG broker firehose sales mapped to the v_sg_sales_by_section shape. DISTINCT ON (sg_sale_id) deduplicates the 11x observation factor. Use for FE views that want to UNION seller-side + broker-side SG sales through one renderer. |
| `v_sg_event_match_proposals` |  |
| `v_sg_events_by_status` |  |
| `v_sg_events_ignored_historic` |  |
| `v_sg_events_pending_match` |  |
| `v_sg_historic_concert_performer` | Per-show concert sales summary per headliner+venue+date. Powers concert/comedy historic baselines and tour-mode aggregations. |
| `v_sg_historic_per_matchup` | Head-to-head matchup history (alphabetized as a-vs-b). Powers find_similar_events scoring and the redesign's comparable-matchups strip. |
| `v_sg_historic_per_performer` | Per-performer-per-season historic sales summary. Rolls up home and away sales for sports performers. Use as input to performer_baselines and the redesign's performer history strip. |
| `v_sg_historic_per_section_kind` | Section-bucket pricing distribution per league + season. Powers the redesign's zone breakdown panel historic baselines. |
| `v_sg_sales_by_event` |  |
| `v_sg_sales_by_section` |  |
| `v_sg_token_budget` | Live SeatGeek shared-token budget from broker response headers (ratelimit-remaining). Reflects external prod program draw. 2026-05-29. |
| `v_sg_unmatched_candidate_performers` |  |
| `v_subreddits_unified` | Reddit subs combined: performer-pinned + leaguewide. scope tells you which. Filter by category=sports + league=NBA to get all NBA-related subs in one query. |
| `v_td_poll_failures_recent` |  |
| `v_td_poll_health` |  |
| `v_td_unmatched_discovered_events` |  |
| `v_team_at_venue_history` | (team, venue, side) aggregates. Shows how a team performs at a specific venue split by home/away. Includes vegas total over/under hit rate. Day-trader use: spot venues where a team consistently over- or under-performs. |
| `v_team_attendance_trend` |  |
| `v_team_last_n_at_venue` | Per (team, venue, side), each game with a games_ago window number. Use WHERE games_ago <= 5 for "last 5 games at this venue". |
| `v_team_recent_results` |  |
| `v_team_roster_full` |  |
| `v_team_schedule_30d` |  |
| `v_team_season_progression` |  |
| `v_team_transactions` |  |
| `v_team_win_prob_trend` |  |
| `v_tevo_blindspot_movers` | TEvo blindspot mover candidates: US/CA events 31-365d out where we own 0 tickets, broker pool has >=25 listings, parking-aware get-in >= $50, big-5 sports excluded, demand signals firing. v1.5 confidence-scored. |
| `v_ticketsdata_credit_usage_daily` |  |
| `v_unmapped_incoming_tokens` | Review queue: tokens users typed that we have no slot mapping for. Sort by occurrences DESC. |
| `v_unmatched_events` | Single bucket of orphan events across all sources. SG events without TEvo xref, SD events without TEvo xref, and TEvo event_ids referenced by orders but missing from our events table. Drives the "find me events I should manually map" workflow. |
| `v_upcoming_rivalry_games` |  |
| `v_venue_climatology` |  |
| `v_venue_neighbors` | All venue-pairs within 50 miles. Refreshes automatically as new venues get geocoded by venue_geocode_queue_5min cron. |
| `v_venue_section_map_coverage` |  |
| `v_wc_price_latest` |  |
| `v_x_accounts_unified` | X-account roster with category/sport/league/team_name + best-effort tevo_performer_id link. Filter by category to slice sports vs broadway vs concerts; filter by sport for league-level (NBA/NFL/MLB/NHL/F1/etc.). |

### Materialized views (4)

| Matview | Size | Comment |
|---|---|---|
| `latest_event_metrics` | 20 MB | Per-event latest event_metrics row, refreshed every 5 min by cron latest_event_metrics_refresh_5min. INTENTIONAL API EXPOSURE: granted to anon/authenticated/service_role so /api/store/events catalog can hit it without authn. Originated PR #71 to fix the 50s catalog timeout. Advisor flag materialized_view_in_api is accepted as expected behavior. |
| `mv_sg_blindspot_movers` | 112 kB |  |
| `mv_tevo_blindspot_movers` | 504 kB |  |
| `v_dashboard_writes_24h` | 56 kB | Dashboard 24h write velocity, refreshed every 15 min by cron dashboard_writes_24h_refresh_60s (was 60s pre-IO-diet PR #86). INTENTIONAL API EXPOSURE for terminal dashboard. Advisor flag materialized_view_in_api is accepted. |

---

## Cron jobs (164, 151 active)

| Job | Schedule | State |
|---|---|---|
| `aq_maps_backfill_daily` | `0 5 * * *` | ON |
| `aq_to_tevo_search_bridge_13h` | `8 * * * *` | ON |
| `auto_ack_stale_alerts_30min` | `9 * * * *` | ON |
| `auto_match_sg_canonical_v3_hourly` | `7 * * * *` | ON |
| `axs-probe-drain` | `*/5 * * * *` | ON |
| `backfill-event-configurations-5min` | `8,38 * * * *` | ON |
| `backfill-order-tevo-from-aq-hourly` | `40 * * * *` | ON |
| `collect-listings-0-24h` | `*/20 * * * *` | ON |
| `collect-listings-1-7d` | `5 * * * *` | ON |
| `collect-listings-30-60d` | `15 */12 * * *` | ON |
| `collect-listings-60d+` | `20 2 * * *` | ON |
| `collect-listings-7-30d` | `10 */4 * * *` | ON |
| `collect-listings-discover-0-24h` | `7 1,9,17 * * *` | ON |
| `collect-listings-discover-1-7d` | `12 1,9,17 * * *` | ON |
| `collect-listings-discover-30-60d` | `22 1,9,17 * * *` | ON |
| `collect-listings-discover-60d` | `27 1,9,17 * * *` | ON |
| `collect-listings-discover-7-30d` | `17 1,9,17 * * *` | ON |
| `compute_alerts_tick_15min` | `11-59/15 * * * *` | OFF |
| `compute_movers_index_post_snapshot` | `35 7,13,19 * * *` | ON |
| `crawl-espn-team-assets-3min` | `12,42 * * * *` | ON |
| `crawl-venues-and-performers-3min` | `10,40 * * * *` | ON |
| `cron_gate_decisions_prune_daily` | `1 9 * * *` | ON |
| `cron-run-details-cleanup` | `15 4 * * *` | ON |
| `cross_source_match_tick_30min` | `9,39 * * * *` | ON |
| `dashboard_writes_24h_refresh_60s` | `8 * * * *` | ON |
| `discovery_gap_refresh` | `0 9 * * *` | ON |
| `dispatch_watchlist_daily_8am` | `0 13 * * *` | ON |
| `ensure-watchlist-coverage-daily` | `15 3 * * *` | ON |
| `entity-metrics-daily-refresh` | `20 */4 * * *` | ON |
| `espn_scoreboard_process_5min` | `7-59/15 * * * *` | ON |
| `espn_scoreboard_queue_4h` | `0 4 * * *` | ON |
| `espn_tournament_process_after_queue` | `10 5 * * 0` | ON |
| `espn_tournament_queue_weekly` | `0 5 * * 0` | ON |
| `espn-gameday-10min` | `*/10 * * * *` | ON |
| `espn-live-score-poll` | `* * * * *` | ON |
| `espn-roster-10min` | `5-59/10 * * * *` | ON |
| `espn-rosters-daily` | `30 8 * * *` | ON |
| `espn-rosters-rotate` | `20 seconds` | ON |
| `espn-team-daily` | `0 5 * * *` | ON |
| `evaluate_user_alerts_10min` | `*/10 * * * *` | ON |
| `evaluate_user_signal_alerts_10min` | `3-59/10 * * * *` | ON |
| `event_competitors_refresh_hourly` | `40 * * * *` | ON |
| `event_section_row_rollup_hourly` | `3 * * * *` | ON |
| `event_sentiment_compute_30min` | `15,45 * * * *` | ON |
| `event_snapshot_evening` | `30 3 * * *` | ON |
| `event_snapshot_midday` | `30 19 * * *` | ON |
| `event_snapshot_morning` | `30 13 * * *` | ON |
| `evo_discover_new_events` | `0 8 * * *` | ON |
| `evo_listings_poll_2min` | `*/2 * * * *` | ON |
| `evo_only_autotag_daily` | `45 8 * * *` | ON |
| `evo_orders_process_30min` | `5,35 * * * *` | ON |
| `evo_orders_queue_30min` | `0,30 * * * *` | ON |
| `exos-mail-drain-2min` | `*/2 * * * *` | ON |
| `fred_process_5min` | `6,36 * * * *` | ON |
| `fred_queue_daily` | `55 3 * * *` | ON |
| `health_monitor_5min` | `*/5 * * * *` | ON |
| `latest_event_metrics_refresh_5min` | `2-59/10 * * * *` | ON |
| `listings_aq_backfill_overnight` | `2-14 4 * * *` | OFF |
| `listings_deltas_backfill_overnight` | `30-44 4 * * *` | ON |
| `master-cascade-2min` | `*/10 * * * *` | OFF |
| `match_events_to_espn_10min` | `14,44 * * * *` | ON |
| `match_listings_to_sg_30min` | `11,41 * * * *` | ON |
| `match_tournaments_daily` | `45 3 * * *` | ON |
| `match_unmatched_orders_sweep_hourly` | `22 * * * *` | ON |
| `midnight-catchup-sweep` | `20 3 * * *` | ON |
| `nws_alerts_process_aligned` | `3,33 * * * *` | ON |
| `nws_alerts_queue_30min` | `1,31 * * * *` | ON |
| `nws_points_process_after_queue` | `40 3 * * *` | ON |
| `nws_points_queue_daily` | `35 3 * * *` | ON |
| `orphan_backfill_sweep_daily` | `30 3 * * *` | ON |
| `orphan_event_backfill_process_15min` | `5-59/15 * * * *` | ON |
| `orphan_event_backfill_queue_15min` | `*/15 * * * *` | OFF |
| `performer_wiki_process_searches_5min` | `19,49 * * * *` | ON |
| `performer_wiki_process_summaries_5min` | `21,51 * * * *` | ON |
| `performer_wiki_queue_searches_5min` | `17,47 * * * *` | ON |
| `refresh_movers_agg` | `20 7,19 * * *` | ON |
| `refresh-chat-corpus` | `26 * * * *` | ON |
| `refresh-chat-term-freq-split-hourly` | `28 * * * *` | ON |
| `resolve-aq-seatdata-link-hourly` | `42 * * * *` | ON |
| `resolve-aq-tevo-from-sources-hourly` | `35 * * * *` | ON |
| `run-daily-chat-audit` | `10 3 * * *` | ON |
| `seatdata_poll_twice_daily` | `0 0,1,15,16 * * *` | ON |
| `seatmap-manifest-sync` | `*/30 * * * *` | ON |
| `sg_blindspot_mv_refresh` | `3-59/10 * * * *` | ON |
| `sg_broker_429_health_check_15min` | `*/15 * * * *` | ON |
| `sg_broker_sales_metrics_refresh_hourly` | `17 * * * *` | ON |
| `sg_canonical_link_overnight` | `46-59 4 * * *` | ON |
| `sg_canonical_v2_pull_refresh_30min` | `12 * * * *` | ON |
| `sg_classify_events_5min` | `*/5 * * * *` | ON |
| `sg_fill_rate_hourly` | `53 * * * *` | ON |
| `sg_force_track_refresh` | `7-59/30 * * * *` | ON |
| `sg_lifetime_sales_daily` | `5 4 * * *` | ON |
| `sg_listings_poll_owned_1min` | `*/4 * * * *` | ON |
| `sg_market_chart_rebuild_daily` | `5 11 * * *` | ON |
| `sg_market_chart_reveal_pull_daily` | `30 10 * * *` | ON |
| `sg_priority_listings_process_5min` | `*/4 * * * *` | ON |
| `sg_priority_sales_process_5min` | `1-59/4 * * * *` | ON |
| `sg_sales_poll_5min` | `1-59/4 * * * *` | ON |
| `sg_seller_listings_queue_30min` | `*/4 * * * *` | ON |
| `sg_seller_orders_queue_30min` | `2 * * * *` | ON |
| `sg_seller_process_30min` | `1-59/4 * * * *` | ON |
| `sg_seller_sync_map_15min` | `*/30 * * * *` | ON |
| `sg_to_tevo_search_bridge_30min` | `23,53 * * * *` | ON |
| `sg_wc_listings_catchup` | `*/2 * * * *` | ON |
| `sg-match-map-tick` | `*/10 * * * *` | ON |
| `sweep_duplicate_listings_hourly` | `15 * * * *` | ON |
| `sweep_expired_pg_net_pending_hourly` | `20 * * * *` | ON |
| `sweep_inactive_event_states_daily` | `50 3 * * *` | ON |
| `sweep_terminal_event_listings_hourly` | `18 * * * *` | ON |
| `sweep_tevo_ticket_groups_cache` | `24 * * * *` | ON |
| `sweep-bot-messages` | `5 3 * * *` | ON |
| `sweep-old-espn-injuries` | `40 3 * * *` | ON |
| `sweep-old-event-section-rows` | `35 3 * * *` | ON |
| `sweep-old-listings` | `0 3 * * *` | ON |
| `sweep-old-section-metrics` | `25 3,9,15,21 * * *` | ON |
| `sweep-old-sg-listings` | `15 3,9,15,21 * * *` | ON |
| `sweep-old-td-listings` | `30 3 * * *` | ON |
| `td_enqueue_peak_gt` | `4-59/10 * * * *` | ON |
| `td_enqueue_peak_sh` | `0-59/10 * * * *` | ON |
| `td_enqueue_peak_tm` | `6-59/10 * * * *` | ON |
| `td_enqueue_peak_tp` | `12 * * * *` | OFF |
| `td_enqueue_peak_vd` | `2-59/10 * * * *` | ON |
| `td_gt_automap_check` | `35 9 * * *` | ON |
| `td_gt_discover` | `15 9 * * *` | ON |
| `td_gt_discover_drain` | `20 9 * * *` | ON |
| `td_match_apply_cron` | `9-59/20 * * * *` | ON |
| `td_match_drain` | `*/5 * * * *` | ON |
| `td_match_fill_enqueue` | `17 */2 * * *` | ON |
| `td_normalize_drain` | `*/2 * * * *` | ON |
| `td_pending_sweep` | `25 * * * *` | ON |
| `td_pull_drain` | `* * * * *` | ON |
| `td_tier_enqueue_axs` | `25,55 * * * *` | OFF |
| `td_tier_enqueue_gt` | `15,45 * * * *` | ON |
| `td_tier_enqueue_sh` | `0,30 * * * *` | ON |
| `td_tier_enqueue_tm` | `10,40 * * * *` | ON |
| `td_tier_enqueue_tp` | `20,50 * * * *` | OFF |
| `td_tier_enqueue_vd` | `5,35 * * * *` | ON |
| `td_tm_discover` | `45 9 * * *` | ON |
| `td_tm_discover_drain` | `50 9 * * *` | ON |
| `td_tp_discover` | `25 9 * * *` | OFF |
| `td_tp_discover_drain` | `30 9 * * *` | OFF |
| `td_watchlist_refresh` | `0 9 * * *` | ON |
| `td-reconcile-knicks-finals-daily` | `5 9 * * *` | ON |
| `tevo_blindspot_discovery_daily` | `0 7 * * *` | ON |
| `tevo_blindspot_metrics_refresh_12h` | `0 6,18 * * *` | ON |
| `tevo_blindspot_mv_refresh` | `7-59/10 * * * *` | OFF |
| `tickpick_orders_process_30min` | `15,45 * * * *` | OFF |
| `tickpick_orders_queue_30min` | `13,43 * * * *` | OFF |
| `tournament_pull_process_weekly` | `30 4 * * 0` | ON |
| `tournament_pull_queue_weekly` | `20 4 * * 0` | ON |
| `tournament_search_pending_sweep_weekly` | `10 4 * * 0` | ON |
| `venue_geocode_process_5min` | `25,55 * * * *` | ON |
| `venue_geocode_queue_5min` | `23,53 * * * *` | ON |
| `venue_pull_process_weekly` | `20 5 * * 0` | ON |
| `venue_pull_queue_weekly` | `40 4 * * 0` | ON |
| `venue_section_map_refresh` | `*/10 * * * *` | ON |
| `vivid_orders_process_30min` | `26 * * * *` | ON |
| `vivid_orders_queue_30min` | `16 * * * *` | ON |
| `wc-price-daily-refresh` | `40 7 * * *` | ON |
| `weather_climatology_weekly` | `0 4 * * 0` | ON |
| `weather_forecast_process_30min` | `29,59 * * * *` | ON |
| `weather_forecast_queue_30min` | `27,57 * * * *` | ON |
| `wiki_pending_sweep_daily` | `25 3 * * *` | ON |
| `zone-backfill-isolated-10min` | `4-59/10 * * * *` | OFF |

---

## Edge functions (29)

_From `supabase/functions/` (excludes `_shared`). For `verify_jwt` + auth notes see `RESOURCES_BIBLE.md` + `PROJECT_BIBLE §1` rule 7._

`alert-mail-drain`, `aq-to-tevo-search-bridge`, `backfill-event-configurations`, `bulk-add-watchlist`, `chat`, `collect`, `collect-listings`, `crawl-espn-team-assets`, `crawl-venues-and-performers`, `espn`, `espn-collect`, `espn-rosters`, `exos-api`, `exos-checkout`, `exos-connect-onboard`, `exos-distribute`, `exos-mail-drain`, `exos-webhook-drain`, `match-sg-performers-to-tevo`, `seatdata-poll`, `seatmap-manifest-sync`, `seed-home-venues`, `sg-seller-webhook`, `sg-to-tevo-search-bridge`, `stripe-webhook`, `tevo-blindspot-discovery`, `tevo-perf-find`, `why-noaa-weather-alerts`, `wiki-collect`
