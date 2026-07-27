-- ============================================================================
-- Migration 20260622190000 — index the 40 unindexed foreign keys
--
-- Lane:     A1 (data plane — indexes/perf)
-- Touches:  40 FK columns across aq_event_map, axs_events, bot_chat, espn_*,
--           exos_*, listings_snapshots, seatgeek_*, order tables, td_*, etc.
--           (additive — CREATE INDEX only; no data/schema change)
-- Pre-reqs: none
--
-- WHY (2026-06-22 audit / performance advisor `unindexed_foreign_keys`):
--   40 FK constraints had no backing index, so a parent delete or a join across
--   the FK seq-scans the (often multi-million-row) child. Adds one btree per FK.
--
--   PARTIAL `WHERE <col> IS NOT NULL`: several of these FK columns are sparsely
--   or ~0% populated (PROJECT_BIBLE §3 — e.g. listings_snapshots /
--   seatgeek_*_snapshots / order-table `aq_short_event_id` are DERIVED via the
--   AQ mapper and mostly NULL). A plain btree would store an entry per NULL row
--   (121M+ on listings_snapshots) for zero benefit — FK matching never uses
--   NULLs. The partial predicate keeps each index to only the populated rows.
--
-- ⚠ PROD APPLY — use CREATE INDEX CONCURRENTLY out-of-band (NON-txn), per repo
--   convention (see 20260622170000 header). A plain in-txn CREATE INDEX takes an
--   ACCESS EXCLUSIVE lock for the full build — unacceptable on listings_snapshots
--   (~121M rows) / seatgeek_listings_snapshots. The `IF NOT EXISTS` form below is
--   the reproducible-on-fresh-DB record; A1 builds each on prod with
--   `CREATE INDEX CONCURRENTLY IF NOT EXISTS <same name> ...` (one statement at a
--   time, off-peak). Re-running this file post-build is a no-op.
-- ============================================================================

-- aq mapper hub
CREATE INDEX IF NOT EXISTS idx_aq_event_map_venue_short_id      ON public.aq_event_map (venue_short_id)      WHERE venue_short_id      IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_aq_event_map_performer_short_id  ON public.aq_event_map (performer_short_id)  WHERE performer_short_id  IS NOT NULL;

-- axs / coordination
CREATE INDEX IF NOT EXISTS idx_axs_events_last_snapshot_id      ON public.axs_events (last_snapshot_id)      WHERE last_snapshot_id    IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bot_chat_in_reply_to             ON public.bot_chat (in_reply_to)             WHERE in_reply_to         IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_canonical_external_ids_source_key ON public.canonical_external_ids (source_key) WHERE source_key       IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_chat_corpus_bot_msg_id           ON public.chat_corpus (bot_msg_id)           WHERE bot_msg_id          IS NOT NULL;

-- espn (composite team+league FKs — scope by espn_league per §3 cross-league collision)
CREATE INDEX IF NOT EXISTS idx_espn_asset_crawl_state_team_league    ON public.espn_asset_crawl_state (espn_team_id, espn_league)    WHERE espn_team_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_espn_athlete_team_history_team_league ON public.espn_athlete_team_history (espn_team_id, espn_league) WHERE espn_team_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_espn_athletes_team_league            ON public.espn_athletes (espn_team_id, espn_league)            WHERE espn_team_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_espn_injuries_snapshots_team_league  ON public.espn_injuries_snapshots (espn_team_id, espn_league)  WHERE espn_team_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_espn_news_team_league               ON public.espn_news (espn_team_id, espn_league)               WHERE espn_team_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_performer_metadata_team_league      ON public.performer_metadata (espn_team_id, espn_league)      WHERE espn_team_id IS NOT NULL;

-- exos ticketing
CREATE INDEX IF NOT EXISTS idx_exos_event_checkins_scanned_by   ON public.exos_event_checkins (scanned_by)   WHERE scanned_by   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_events_created_by           ON public.exos_events (created_by)           WHERE created_by   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_mail_created_by             ON public.exos_mail (created_by)             WHERE created_by   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_org_invites_created_by      ON public.exos_org_invites (created_by)      WHERE created_by   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_org_invites_claimed_by      ON public.exos_org_invites (claimed_by)      WHERE claimed_by   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_org_memberships_added_by    ON public.exos_org_memberships (added_by)    WHERE added_by     IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_orgs_owner_uid              ON public.exos_orgs (owner_uid)              WHERE owner_uid    IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_scan_rejects_rejected_by    ON public.exos_scan_rejects (rejected_by)    WHERE rejected_by  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_tickets_voided_by           ON public.exos_tickets (voided_by)           WHERE voided_by    IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_tickets_tier_id             ON public.exos_tickets (tier_id)             WHERE tier_id      IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_exos_tickets_buyer_id            ON public.exos_tickets (buyer_id)            WHERE buyer_id     IS NOT NULL;

-- firehose snapshots (large tables — CONCURRENTLY mandatory on prod)
CREATE INDEX IF NOT EXISTS idx_listings_snapshots_performer_short_id ON public.listings_snapshots (performer_short_id) WHERE performer_short_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_listings_snapshots_venue_short_id     ON public.listings_snapshots (venue_short_id)     WHERE venue_short_id     IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_listings_snapshots_aq_short_event_id  ON public.listings_snapshots (aq_short_event_id)  WHERE aq_short_event_id  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sg_listings_snapshots_performer_short_id ON public.seatgeek_listings_snapshots (performer_short_id) WHERE performer_short_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sg_listings_snapshots_aq_short_event_id  ON public.seatgeek_listings_snapshots (aq_short_event_id)  WHERE aq_short_event_id  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sg_sales_snapshots_aq_short_event_id     ON public.seatgeek_sales_snapshots (aq_short_event_id)     WHERE aq_short_event_id  IS NOT NULL;

-- orders / discovery / misc
CREATE INDEX IF NOT EXISTS idx_evo_order_items_aq_short_event_id ON public.evo_order_items (aq_short_event_id) WHERE aq_short_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_seatgeek_orders_aq_short_event_id ON public.seatgeek_orders (aq_short_event_id) WHERE aq_short_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_tickpick_orders_aq_short_event_id ON public.tickpick_orders (aq_short_event_id) WHERE aq_short_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_vivid_orders_aq_short_event_id    ON public.vivid_orders (aq_short_event_id)    WHERE aq_short_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_seatgeek_pull_log_sg_event_id     ON public.seatgeek_pull_log (sg_event_id)     WHERE sg_event_id  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sg_listings_pending_sg_event_id   ON public.sg_listings_pending (sg_event_id)   WHERE sg_event_id  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_major_event_calendar_tevo_venue_id ON public.major_event_calendar (tevo_venue_id) WHERE tevo_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_td_discovered_events_target_id    ON public.td_discovered_events (target_id)    WHERE target_id    IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_td_match_results_queue_id         ON public.td_match_results (queue_id)         WHERE queue_id     IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_alerts_metric_key            ON public.user_alerts (metric_key)            WHERE metric_key   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_weather_observations_source_key   ON public.weather_observations (source_key)   WHERE source_key   IS NOT NULL;
