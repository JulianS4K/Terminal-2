-- ============================================================================
-- Migration 20260510120200 — Phase 3: canonical_external_ids backfill
--
-- Lane:     canonical
-- Touches:  data_sources (W), performer_external_ids (W),
--           canonical_external_ids (W),
--           event_xref (R), seatgeek_event_xref (R), seatdata_event_xref (R),
--           seatgeek_venue_xref (R), seatdata_venue_xref (R),
--           seatgeek_performer_xref (R), seatdata_performer_xref (R),
--           performer_espn_team_xref (R), venue_assets (R),
--           performer_wikipedia (R)
-- Pre-reqs: 20260510120030 (Phase 1), 20260510120100 (Phase 2),
--           20260509210000 (canonical_external_ids exists)
--
-- Backfill canonical_external_ids — the unified per-entity registry.
-- Pre-step (vocabulary normalization):
--   * canonical_external_ids.source_key has an FK to data_sources.source_key,
--     so every key we use here must already exist in data_sources.
--   * Add 'espn_team' as a first-class source (team-identity flavor of ESPN).
--   * Normalize legacy performer_external_ids.source='seatgeek' to 'sg_broker'
--     to match the data_sources vocabulary.
--
-- Then mirror every per-source xref into canonical_external_ids using these
-- source keys: 'espn' | 'sg_broker' | 'seatdata' | 'wikipedia' | 'espn_team'.
-- ============================================================================

-- 0a. add espn_team as a registered data source if missing
INSERT INTO data_sources (source_key, display_name, kind, host, auth_method, read_only, notes)
VALUES ('espn_team', 'ESPN (team identity)', 'enrichment', 'site.api.espn.com',
        'public', true,
        'Team-level ESPN linkage stored in performer_espn_team_xref. Sub-source of espn.')
ON CONFLICT (source_key) DO NOTHING;

-- 0b. normalize legacy 'seatgeek' source rows to 'sg_broker' (matches data_sources)
UPDATE performer_external_ids
   SET source = 'sg_broker'
 WHERE source = 'seatgeek';

-- ----------------------------------------------------------------------------
-- events × espn
-- ----------------------------------------------------------------------------
INSERT INTO canonical_external_ids (
    entity_kind, tevo_id, source_key, external_id, external_name,
    match_method, match_confidence, matched_at, meta)
SELECT 'event', tevo_event_id, 'espn', espn_event_id, NULL,
       match_method, NULL, matched_at,
       jsonb_strip_nulls(jsonb_build_object(
         'espn_league', espn_league,
         'espn_slug',   espn_slug)) || COALESCE(meta, '{}'::jsonb)
  FROM event_xref
ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
  SET external_id      = EXCLUDED.external_id,
      external_name    = EXCLUDED.external_name,
      match_method     = EXCLUDED.match_method,
      match_confidence = EXCLUDED.match_confidence,
      matched_at       = EXCLUDED.matched_at,
      meta             = EXCLUDED.meta;

-- events × sg_broker
INSERT INTO canonical_external_ids (
    entity_kind, tevo_id, source_key, external_id, external_name,
    match_method, match_confidence, matched_at, meta)
SELECT 'event', tevo_event_id, 'sg_broker', sg_event_id::text, sg_event_name,
       match_method, match_confidence, matched_at, COALESCE(meta, '{}'::jsonb)
  FROM seatgeek_event_xref
ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
  SET external_id      = EXCLUDED.external_id,
      external_name    = EXCLUDED.external_name,
      match_method     = EXCLUDED.match_method,
      match_confidence = EXCLUDED.match_confidence,
      matched_at       = EXCLUDED.matched_at,
      meta             = EXCLUDED.meta;

-- events × seatdata
INSERT INTO canonical_external_ids (
    entity_kind, tevo_id, source_key, external_id, external_name,
    match_method, match_confidence, matched_at, meta)
SELECT 'event', tevo_event_id, 'seatdata', sd_event_id::text, NULL,
       match_method, match_confidence, matched_at,
       jsonb_strip_nulls(jsonb_build_object(
         'sd_tm_event_id',  sd_tm_event_id,
         'sd_std_event_id', sd_std_event_id,
         'sd_std_venue_id', sd_std_venue_id)) || COALESCE(meta, '{}'::jsonb)
  FROM seatdata_event_xref
ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
  SET external_id      = EXCLUDED.external_id,
      match_method     = EXCLUDED.match_method,
      match_confidence = EXCLUDED.match_confidence,
      matched_at       = EXCLUDED.matched_at,
      meta             = EXCLUDED.meta;

-- ----------------------------------------------------------------------------
-- venues × espn (from venue_assets.espn_venue_id)
-- ----------------------------------------------------------------------------
INSERT INTO canonical_external_ids (
    entity_kind, tevo_id, source_key, external_id, external_name,
    match_method, matched_at, meta)
SELECT 'venue', tevo_venue_id, 'espn', espn_venue_id, espn_venue_name,
       'venue_assets_join', COALESCE(fetched_at, NOW()),
       jsonb_build_object('origin', 'venue_assets')
  FROM venue_assets
 WHERE espn_venue_id IS NOT NULL
ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
  SET external_id   = EXCLUDED.external_id,
      external_name = EXCLUDED.external_name,
      match_method  = EXCLUDED.match_method,
      matched_at    = EXCLUDED.matched_at,
      meta          = EXCLUDED.meta;

-- venues × sg_broker
INSERT INTO canonical_external_ids (
    entity_kind, tevo_id, source_key, external_id, external_name,
    match_method, match_confidence, matched_at, meta)
SELECT 'venue', tevo_venue_id, 'sg_broker',
       md5(lower(sg_venue_name)), sg_venue_name,
       match_method, match_confidence, matched_at, COALESCE(meta, '{}'::jsonb)
  FROM seatgeek_venue_xref
ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
  SET external_id      = EXCLUDED.external_id,
      external_name    = EXCLUDED.external_name,
      match_method     = EXCLUDED.match_method,
      match_confidence = EXCLUDED.match_confidence,
      matched_at       = EXCLUDED.matched_at,
      meta             = EXCLUDED.meta;

-- venues × seatdata
INSERT INTO canonical_external_ids (
    entity_kind, tevo_id, source_key, external_id, external_name,
    match_method, match_confidence, matched_at, meta)
SELECT 'venue', tevo_venue_id, 'seatdata',
       COALESCE(sd_std_venue_id::text, md5(lower(sd_venue_name))),
       sd_venue_name, match_method, match_confidence, matched_at,
       jsonb_strip_nulls(jsonb_build_object(
         'sd_venue_slug',  sd_venue_slug,
         'sd_venue_city',  sd_venue_city,
         'sd_venue_state', sd_venue_state)) || COALESCE(meta, '{}'::jsonb)
  FROM seatdata_venue_xref
ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
  SET external_id      = EXCLUDED.external_id,
      external_name    = EXCLUDED.external_name,
      match_method     = EXCLUDED.match_method,
      match_confidence = EXCLUDED.match_confidence,
      matched_at       = EXCLUDED.matched_at,
      meta             = EXCLUDED.meta;

-- ----------------------------------------------------------------------------
-- performers × every source (mirror performer_external_ids verbatim)
-- ----------------------------------------------------------------------------
INSERT INTO canonical_external_ids (
    entity_kind, tevo_id, source_key, external_id, external_name,
    match_method, matched_at, meta)
SELECT 'performer', performer_id, source, external_id, external_name,
       NULL, set_at,
       jsonb_strip_nulls(jsonb_build_object('league', league)) || COALESCE(meta, '{}'::jsonb)
  FROM performer_external_ids
ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
  SET external_id   = EXCLUDED.external_id,
      external_name = EXCLUDED.external_name,
      matched_at    = EXCLUDED.matched_at,
      meta          = EXCLUDED.meta;

-- performers × espn_team (collapse multi-league rows; preserves all leagues in meta)
INSERT INTO canonical_external_ids (
    entity_kind, tevo_id, source_key, external_id, external_name,
    match_method, matched_at, meta)
SELECT 'performer', tevo_performer_id, 'espn_team',
       (array_agg(espn_team_id ORDER BY espn_league))[1], NULL,
       (array_agg(match_method ORDER BY espn_league))[1], NOW(),
       jsonb_build_object(
         'leagues',  array_agg(DISTINCT espn_league),
         'team_ids', jsonb_object_agg(espn_league, espn_team_id))
  FROM performer_espn_team_xref
 GROUP BY tevo_performer_id
ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
  SET external_id  = EXCLUDED.external_id,
      match_method = EXCLUDED.match_method,
      matched_at   = EXCLUDED.matched_at,
      meta         = EXCLUDED.meta;
