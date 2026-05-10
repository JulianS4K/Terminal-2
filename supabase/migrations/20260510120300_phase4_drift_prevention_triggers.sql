-- ============================================================================
-- Phase 4: drift-prevention triggers.
--
-- For each per-source xref table, install an AFTER INSERT/UPDATE/DELETE
-- trigger that mirrors the row into canonical_external_ids using the
-- normalized vocabulary from data_sources.
--
-- Special-case: sg_events_canonical → seatgeek_event_xref. The cron auto-match
-- writes tevo_event_id directly onto sg_events_canonical; this trigger then
-- ensures seatgeek_event_xref always reflects the match (closing the historical
-- 218 vs 10 drift).
-- ============================================================================

-- event_xref → canonical_external_ids (espn)
CREATE OR REPLACE FUNCTION trg_sync_cei__event_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='event' AND tevo_id=OLD.tevo_event_id AND source_key='espn';
    RETURN OLD;
  END IF;
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, matched_at, meta)
  VALUES ('event', NEW.tevo_event_id, 'espn', NEW.espn_event_id, NULL,
          NEW.match_method, NEW.matched_at,
          jsonb_strip_nulls(jsonb_build_object(
            'espn_league', NEW.espn_league,
            'espn_slug',   NEW.espn_slug)) || COALESCE(NEW.meta, '{}'::jsonb))
  ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
    SET external_id  = EXCLUDED.external_id,
        match_method = EXCLUDED.match_method,
        matched_at   = EXCLUDED.matched_at,
        meta         = EXCLUDED.meta;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS event_xref_cei_sync ON event_xref;
CREATE TRIGGER event_xref_cei_sync
  AFTER INSERT OR UPDATE OR DELETE ON event_xref
  FOR EACH ROW EXECUTE FUNCTION trg_sync_cei__event_xref();

-- seatgeek_event_xref → canonical_external_ids (sg_broker)
CREATE OR REPLACE FUNCTION trg_sync_cei__sg_event_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='event' AND tevo_id=OLD.tevo_event_id AND source_key='sg_broker';
    RETURN OLD;
  END IF;
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, match_confidence, matched_at, meta)
  VALUES ('event', NEW.tevo_event_id, 'sg_broker', NEW.sg_event_id::text,
          NEW.sg_event_name, NEW.match_method, NEW.match_confidence,
          NEW.matched_at, COALESCE(NEW.meta, '{}'::jsonb))
  ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
    SET external_id      = EXCLUDED.external_id,
        external_name    = EXCLUDED.external_name,
        match_method     = EXCLUDED.match_method,
        match_confidence = EXCLUDED.match_confidence,
        matched_at       = EXCLUDED.matched_at,
        meta             = EXCLUDED.meta;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS seatgeek_event_xref_cei_sync ON seatgeek_event_xref;
CREATE TRIGGER seatgeek_event_xref_cei_sync
  AFTER INSERT OR UPDATE OR DELETE ON seatgeek_event_xref
  FOR EACH ROW EXECUTE FUNCTION trg_sync_cei__sg_event_xref();

-- seatdata_event_xref → canonical_external_ids (seatdata)
CREATE OR REPLACE FUNCTION trg_sync_cei__sd_event_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='event' AND tevo_id=OLD.tevo_event_id AND source_key='seatdata';
    RETURN OLD;
  END IF;
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, match_confidence, matched_at, meta)
  VALUES ('event', NEW.tevo_event_id, 'seatdata', NEW.sd_event_id::text, NULL,
          NEW.match_method, NEW.match_confidence, NEW.matched_at,
          jsonb_strip_nulls(jsonb_build_object(
            'sd_tm_event_id',  NEW.sd_tm_event_id,
            'sd_std_event_id', NEW.sd_std_event_id,
            'sd_std_venue_id', NEW.sd_std_venue_id)) || COALESCE(NEW.meta, '{}'::jsonb))
  ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
    SET external_id      = EXCLUDED.external_id,
        match_method     = EXCLUDED.match_method,
        match_confidence = EXCLUDED.match_confidence,
        matched_at       = EXCLUDED.matched_at,
        meta             = EXCLUDED.meta;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS seatdata_event_xref_cei_sync ON seatdata_event_xref;
CREATE TRIGGER seatdata_event_xref_cei_sync
  AFTER INSERT OR UPDATE OR DELETE ON seatdata_event_xref
  FOR EACH ROW EXECUTE FUNCTION trg_sync_cei__sd_event_xref();

-- seatgeek_venue_xref → canonical_external_ids (sg_broker / venue)
CREATE OR REPLACE FUNCTION trg_sync_cei__sg_venue_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='venue' AND tevo_id=OLD.tevo_venue_id AND source_key='sg_broker';
    RETURN OLD;
  END IF;
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, match_confidence, matched_at, meta)
  VALUES ('venue', NEW.tevo_venue_id, 'sg_broker',
          md5(lower(NEW.sg_venue_name)), NEW.sg_venue_name,
          NEW.match_method, NEW.match_confidence, NEW.matched_at,
          COALESCE(NEW.meta, '{}'::jsonb))
  ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
    SET external_id      = EXCLUDED.external_id,
        external_name    = EXCLUDED.external_name,
        match_method     = EXCLUDED.match_method,
        match_confidence = EXCLUDED.match_confidence,
        matched_at       = EXCLUDED.matched_at,
        meta             = EXCLUDED.meta;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS seatgeek_venue_xref_cei_sync ON seatgeek_venue_xref;
CREATE TRIGGER seatgeek_venue_xref_cei_sync
  AFTER INSERT OR UPDATE OR DELETE ON seatgeek_venue_xref
  FOR EACH ROW EXECUTE FUNCTION trg_sync_cei__sg_venue_xref();

-- seatdata_venue_xref → canonical_external_ids (seatdata / venue)
CREATE OR REPLACE FUNCTION trg_sync_cei__sd_venue_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='venue' AND tevo_id=OLD.tevo_venue_id AND source_key='seatdata';
    RETURN OLD;
  END IF;
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, match_confidence, matched_at, meta)
  VALUES ('venue', NEW.tevo_venue_id, 'seatdata',
          COALESCE(NEW.sd_std_venue_id::text, md5(lower(NEW.sd_venue_name))),
          NEW.sd_venue_name,
          NEW.match_method, NEW.match_confidence, NEW.matched_at,
          jsonb_strip_nulls(jsonb_build_object(
            'sd_venue_slug',  NEW.sd_venue_slug,
            'sd_venue_city',  NEW.sd_venue_city,
            'sd_venue_state', NEW.sd_venue_state)) || COALESCE(NEW.meta, '{}'::jsonb))
  ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
    SET external_id      = EXCLUDED.external_id,
        external_name    = EXCLUDED.external_name,
        match_method     = EXCLUDED.match_method,
        match_confidence = EXCLUDED.match_confidence,
        matched_at       = EXCLUDED.matched_at,
        meta             = EXCLUDED.meta;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS seatdata_venue_xref_cei_sync ON seatdata_venue_xref;
CREATE TRIGGER seatdata_venue_xref_cei_sync
  AFTER INSERT OR UPDATE OR DELETE ON seatdata_venue_xref
  FOR EACH ROW EXECUTE FUNCTION trg_sync_cei__sd_venue_xref();

-- venue_assets.espn_venue_id → canonical_external_ids (espn / venue)
CREATE OR REPLACE FUNCTION trg_sync_cei__venue_assets_espn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='venue' AND tevo_id=OLD.tevo_venue_id AND source_key='espn';
    RETURN OLD;
  END IF;
  IF NEW.espn_venue_id IS NULL THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='venue' AND tevo_id=NEW.tevo_venue_id AND source_key='espn';
    RETURN NEW;
  END IF;
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, matched_at, meta)
  VALUES ('venue', NEW.tevo_venue_id, 'espn', NEW.espn_venue_id, NEW.espn_venue_name,
          'venue_assets_join', COALESCE(NEW.fetched_at, NOW()),
          jsonb_build_object('origin','venue_assets'))
  ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
    SET external_id   = EXCLUDED.external_id,
        external_name = EXCLUDED.external_name,
        matched_at    = EXCLUDED.matched_at,
        meta          = EXCLUDED.meta;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS venue_assets_espn_cei_sync ON venue_assets;
CREATE TRIGGER venue_assets_espn_cei_sync
  AFTER INSERT OR UPDATE OF espn_venue_id, espn_venue_name OR DELETE ON venue_assets
  FOR EACH ROW EXECUTE FUNCTION trg_sync_cei__venue_assets_espn();

-- performer_external_ids → canonical_external_ids (mirrors all sources)
CREATE OR REPLACE FUNCTION trg_sync_cei__performer_external_ids()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='performer'
       AND tevo_id=OLD.performer_id
       AND source_key=OLD.source;
    RETURN OLD;
  END IF;
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      matched_at, meta)
  VALUES ('performer', NEW.performer_id, NEW.source,
          NEW.external_id, NEW.external_name, NEW.set_at,
          jsonb_strip_nulls(jsonb_build_object('league', NEW.league))
            || COALESCE(NEW.meta, '{}'::jsonb))
  ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
    SET external_id   = EXCLUDED.external_id,
        external_name = EXCLUDED.external_name,
        matched_at    = EXCLUDED.matched_at,
        meta          = EXCLUDED.meta;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS performer_external_ids_cei_sync ON performer_external_ids;
CREATE TRIGGER performer_external_ids_cei_sync
  AFTER INSERT OR UPDATE OR DELETE ON performer_external_ids
  FOR EACH ROW EXECUTE FUNCTION trg_sync_cei__performer_external_ids();

-- seatgeek_performer_xref → performer_external_ids (cascades to canonical via trigger above)
CREATE OR REPLACE FUNCTION trg_sync_pei__sg_perf_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM performer_external_ids
     WHERE performer_id=OLD.tevo_performer_id AND source='sg_broker';
    RETURN OLD;
  END IF;
  INSERT INTO performer_external_ids (
      performer_id, source, external_id, external_name, league, meta, set_at)
  VALUES (NEW.tevo_performer_id, 'sg_broker',
          md5(lower(NEW.sg_performer_name)), NEW.sg_performer_name, NULL,
          jsonb_strip_nulls(jsonb_build_object(
            'match_method',     NEW.match_method,
            'match_confidence', NEW.match_confidence)) || COALESCE(NEW.meta, '{}'::jsonb),
          NEW.matched_at)
  ON CONFLICT (performer_id, source) DO UPDATE
    SET external_id   = EXCLUDED.external_id,
        external_name = EXCLUDED.external_name,
        meta          = EXCLUDED.meta,
        set_at        = EXCLUDED.set_at;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS seatgeek_perf_xref_pei_sync ON seatgeek_performer_xref;
CREATE TRIGGER seatgeek_perf_xref_pei_sync
  AFTER INSERT OR UPDATE OR DELETE ON seatgeek_performer_xref
  FOR EACH ROW EXECUTE FUNCTION trg_sync_pei__sg_perf_xref();

-- seatdata_performer_xref → performer_external_ids
CREATE OR REPLACE FUNCTION trg_sync_pei__sd_perf_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM performer_external_ids
     WHERE performer_id=OLD.tevo_performer_id AND source='seatdata';
    RETURN OLD;
  END IF;
  INSERT INTO performer_external_ids (
      performer_id, source, external_id, external_name, league, meta, set_at)
  VALUES (NEW.tevo_performer_id, 'seatdata',
          md5(lower(NEW.sd_performer_name)), NEW.sd_performer_name, NULL,
          jsonb_strip_nulls(jsonb_build_object(
            'match_method',     NEW.match_method,
            'match_confidence', NEW.match_confidence,
            'sd_std_event_id',  NEW.sd_std_event_id)) || COALESCE(NEW.meta, '{}'::jsonb),
          NEW.matched_at)
  ON CONFLICT (performer_id, source) DO UPDATE
    SET external_id   = EXCLUDED.external_id,
        external_name = EXCLUDED.external_name,
        meta          = EXCLUDED.meta,
        set_at        = EXCLUDED.set_at;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS seatdata_perf_xref_pei_sync ON seatdata_performer_xref;
CREATE TRIGGER seatdata_perf_xref_pei_sync
  AFTER INSERT OR UPDATE OR DELETE ON seatdata_performer_xref
  FOR EACH ROW EXECUTE FUNCTION trg_sync_pei__sd_perf_xref();

-- performer_wikipedia → performer_external_ids (skip rejected matches)
CREATE OR REPLACE FUNCTION trg_sync_pei__wikipedia()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (TG_OP = 'DELETE') OR COALESCE(NEW.is_rejected, false) THEN
    DELETE FROM performer_external_ids
     WHERE performer_id = COALESCE(NEW.tevo_performer_id, OLD.tevo_performer_id)
       AND source = 'wikipedia';
    IF (TG_OP = 'DELETE') THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.wiki_title IS NULL THEN
    RETURN NEW;
  END IF;
  INSERT INTO performer_external_ids (
      performer_id, source, external_id, external_name, league, meta, set_at)
  VALUES (NEW.tevo_performer_id, 'wikipedia',
          COALESCE(NEW.wiki_pageid::text, md5(lower(NEW.wiki_title))),
          NEW.wiki_title, NULL,
          jsonb_strip_nulls(jsonb_build_object(
            'wiki_url',          NEW.wiki_url,
            'wiki_lang',         NEW.wiki_lang,
            'description',       NEW.description,
            'image_url',         NEW.image_url,
            'match_method',      NEW.match_method,
            'match_confidence',  NEW.match_confidence)),
          COALESCE(NEW.last_refreshed_at, NEW.updated_at, NEW.created_at, NOW()))
  ON CONFLICT (performer_id, source) DO UPDATE
    SET external_id   = EXCLUDED.external_id,
        external_name = EXCLUDED.external_name,
        meta          = EXCLUDED.meta,
        set_at        = EXCLUDED.set_at;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS performer_wikipedia_pei_sync ON performer_wikipedia;
CREATE TRIGGER performer_wikipedia_pei_sync
  AFTER INSERT OR UPDATE OR DELETE ON performer_wikipedia
  FOR EACH ROW EXECUTE FUNCTION trg_sync_pei__wikipedia();

-- performer_espn_team_xref → canonical_external_ids (source_key='espn_team',
-- aggregates multi-league rows for the same performer)
CREATE OR REPLACE FUNCTION trg_sync_cei__perf_espn_team_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_pid bigint := COALESCE(NEW.tevo_performer_id, OLD.tevo_performer_id);
  v_team_id text;
  v_leagues text[];
  v_team_ids jsonb;
  v_match_method text;
BEGIN
  SELECT (array_agg(espn_team_id ORDER BY espn_league))[1],
         array_agg(DISTINCT espn_league),
         jsonb_object_agg(espn_league, espn_team_id),
         (array_agg(match_method ORDER BY espn_league))[1]
    INTO v_team_id, v_leagues, v_team_ids, v_match_method
    FROM performer_espn_team_xref
   WHERE tevo_performer_id = v_pid;

  IF v_team_id IS NULL THEN
    DELETE FROM canonical_external_ids
     WHERE entity_kind='performer' AND tevo_id=v_pid AND source_key='espn_team';
  ELSE
    INSERT INTO canonical_external_ids (
        entity_kind, tevo_id, source_key, external_id, external_name,
        match_method, matched_at, meta)
    VALUES ('performer', v_pid, 'espn_team', v_team_id, NULL,
            v_match_method, NOW(),
            jsonb_build_object('leagues', v_leagues, 'team_ids', v_team_ids))
    ON CONFLICT (entity_kind, tevo_id, source_key) DO UPDATE
      SET external_id  = EXCLUDED.external_id,
          match_method = EXCLUDED.match_method,
          matched_at   = EXCLUDED.matched_at,
          meta         = EXCLUDED.meta;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;
DROP TRIGGER IF EXISTS performer_espn_team_xref_cei_sync ON performer_espn_team_xref;
CREATE TRIGGER performer_espn_team_xref_cei_sync
  AFTER INSERT OR UPDATE OR DELETE ON performer_espn_team_xref
  FOR EACH ROW EXECUTE FUNCTION trg_sync_cei__perf_espn_team_xref();

-- sg_events_canonical → seatgeek_event_xref
-- (auto-link SG events the moment they get their tevo_event_id; the cascade
-- then mirrors via seatgeek_event_xref_cei_sync into canonical_external_ids)
CREATE OR REPLACE FUNCTION trg_sgec_to_seatgeek_event_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.tevo_event_id IS NULL THEN
    RETURN NEW;
  END IF;
  INSERT INTO seatgeek_event_xref (
      tevo_event_id, sg_event_id, sg_event_name, sg_event_type, sg_event_location,
      sg_start_data, matched_at, match_method, match_confidence, meta)
  VALUES (NEW.tevo_event_id, NEW.sg_event_id, NEW.sg_event_name, NEW.sg_category,
          NULLIF(concat_ws(', ', NEW.sg_venue_name, NEW.sg_venue_city, NEW.sg_venue_state), ''),
          NEW.sg_datetime_utc, COALESCE(NEW.matched_at, NOW()),
          COALESCE(NEW.match_method, 'sg_canonical_auto'),
          NEW.match_confidence,
          jsonb_build_object('origin','sg_events_canonical'))
  ON CONFLICT (tevo_event_id) DO UPDATE
    SET sg_event_id       = EXCLUDED.sg_event_id,
        sg_event_name     = EXCLUDED.sg_event_name,
        sg_event_type     = EXCLUDED.sg_event_type,
        sg_event_location = EXCLUDED.sg_event_location,
        sg_start_data     = EXCLUDED.sg_start_data,
        match_method      = EXCLUDED.match_method,
        match_confidence  = EXCLUDED.match_confidence,
        matched_at        = EXCLUDED.matched_at,
        meta              = EXCLUDED.meta;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS sg_events_canonical_to_xref ON sg_events_canonical;
CREATE TRIGGER sg_events_canonical_to_xref
  AFTER INSERT OR UPDATE OF tevo_event_id ON sg_events_canonical
  FOR EACH ROW EXECUTE FUNCTION trg_sgec_to_seatgeek_event_xref();
