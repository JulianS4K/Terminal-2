-- Cross-source entity maps — single place to translate any source's id
-- to all other sources' ids. TEvo id is the hub.
-- Applied to prod 2026-05-09 ~03:30 UTC.
--
-- Why: we have xref tables scattered across each integration (event_xref
-- for ESPN, seatdata_event_xref, seatgeek_event_xref, performer_external_ids,
-- seatdata_performer_xref, seatgeek_performer_xref, etc.). To answer
-- "given any source's id for entity X, get the others", you'd JOIN 5+
-- tables. This migration consolidates that into 3 entity-map views and
-- a small set of translation functions.
--
-- Architecture (TEvo as hub, all sources xref independently to TEvo):
--
--      TEvo (hub)
--        │
--        ├── ESPN         (event_xref, performer_external_ids source='espn')
--        ├── SeatData     (seatdata_*_xref tables)
--        ├── SeatGeek     (seatgeek_*_xref tables)
--        └── (future)     SeatGeek public API, Vivid Seats, TickPick, etc.
--
-- Schema additions:
--
--   entity_event_map        VIEW — one row per TEvo event, with all
--                                  external ids + source metadata
--   entity_performer_map    VIEW — one row per TEvo performer
--   entity_venue_map        VIEW — one row per TEvo venue
--   taxonomy_xref           TABLE — league + event_type cross-mapping
--                                   (TEvo "game" → ESPN "NBA" → SG "nba" etc.)
--   cross_source_coverage   VIEW — diagnostic: per-source link rate
--
-- Functions (translation helpers):
--
--   tevo_event_id_for(source, external_id)        → bigint
--   tevo_performer_id_for(source, external_id)    → bigint
--   tevo_venue_id_for(source, external_id)        → bigint
--   external_ids_for_event(tevo_event_id)         → jsonb { espn, sd, sg, ... }
--   external_ids_for_performer(tevo_performer_id) → jsonb
--   external_ids_for_venue(tevo_venue_id)         → jsonb

BEGIN;

-- ============================================================
-- A. Taxonomy cross-mapping (the "fixed variables")
-- ============================================================
-- TEvo, ESPN, SG, SeatData each tag events with their own taxonomy.
-- This table is the rosetta stone for: "is this an NBA game?" =
-- TEvo event_type='game' AND primary_performer in NBA AND
-- ESPN espn_league='NBA' AND SG sg_event_type='nba' AND
-- SeatData event_type='basketball'.

CREATE TABLE IF NOT EXISTS taxonomy_xref (
  id                  bigserial PRIMARY KEY,
  canonical_label     text NOT NULL,           -- our preferred name: 'NBA', 'MLB', 'concert', etc.
  canonical_kind      text NOT NULL,           -- 'league' | 'event_type' | 'sport' | 'genre'
  tevo_event_type     text,                    -- value from events.event_type
  tevo_top_category   text,                    -- value from performer_metadata.top_category_name
  espn_league         text,                    -- value seen in espn_team_snapshots.espn_league
  sg_event_type       text,                    -- value from seatgeek_seller_listings.sg_event_type / orders
  sd_event_type       text,                    -- value from SeatData event payloads
  notes               text,
  created_at          timestamptz DEFAULT NOW(),
  CONSTRAINT taxonomy_xref_canonical_unique UNIQUE (canonical_kind, canonical_label)
);
CREATE INDEX IF NOT EXISTS idx_tax_xref_tevo_etype ON taxonomy_xref(tevo_event_type);
CREATE INDEX IF NOT EXISTS idx_tax_xref_espn      ON taxonomy_xref(espn_league);
CREATE INDEX IF NOT EXISTS idx_tax_xref_sg        ON taxonomy_xref(sg_event_type);

-- Seed the major leagues + types we know
INSERT INTO taxonomy_xref (canonical_label, canonical_kind, tevo_event_type, espn_league, sg_event_type, sd_event_type, notes) VALUES
  ('NBA',         'league', 'game', 'NBA',        'nba',           'basketball',  'National Basketball Association'),
  ('WNBA',        'league', 'game', 'WNBA',       'wnba',          'basketball',  'Womens National Basketball Association'),
  ('NFL',         'league', 'game', 'NFL',        'nfl',           'football',    'National Football League'),
  ('NHL',         'league', 'game', 'NHL',        'nhl',           'hockey',      'National Hockey League'),
  ('MLB',         'league', 'game', 'MLB',        'mlb',           'baseball',    'Major League Baseball'),
  ('MLS',         'league', 'game', 'MLS',        'mls',           'soccer',      'Major League Soccer'),
  ('NCAA-FB',     'league', 'game', 'NCAAF',      'ncaa_football', 'football',    'NCAA Football'),
  ('NCAA-MBB',    'league', 'game', 'NCAA',       'ncaa_basketball','basketball', 'NCAA Mens Basketball'),
  ('Concert',     'event_type', 'concert', NULL,       'concert',     'concert',  'Concerts'),
  ('Comedy',      'event_type', 'concert', NULL,       'comedy',      'comedy',   'Comedy / standup'),
  ('Theater',     'event_type', 'concert', NULL,       'theater',     'theater',  'Theater / Broadway'),
  ('Parking',     'event_type', NULL,      NULL,       'parking',     NULL,       'Parking passes (ancillary)')
ON CONFLICT (canonical_kind, canonical_label) DO NOTHING;

-- ============================================================
-- B. Entity event map — TEvo event ↔ all sources
-- ============================================================

CREATE OR REPLACE VIEW public.entity_event_map AS
SELECT
  e.id                                     AS tevo_event_id,
  e.name                                   AS tevo_name,
  e.occurs_at_local::date                  AS event_date,
  e.venue_id                               AS tevo_venue_id,
  e.venue_name                             AS tevo_venue_name,
  e.primary_performer_id                   AS tevo_primary_performer_id,
  e.primary_performer_name                 AS tevo_primary_performer_name,
  e.event_type                             AS tevo_event_type,
  -- ESPN
  ex.espn_event_id                         AS espn_event_id,
  ex.espn_league                           AS espn_league,
  ex.espn_slug                             AS espn_slug,
  -- SeatData
  sdx.sd_event_id                          AS sd_event_id,
  sdx.match_method                         AS sd_match_method,
  -- SeatGeek (broker host xref, manual)
  sgx.sg_event_id                          AS sg_event_id,
  sgx.sg_event_name                        AS sg_event_name,
  sgx.sg_event_location                    AS sg_event_location,
  sgx.match_method                         AS sg_match_method,
  -- Lifecycle (gh / completed / cancelled signal)
  lc.status                                AS lifecycle_status,
  lc.is_active                             AS lifecycle_is_active,
  -- Coverage flag
  (CASE WHEN ex.espn_event_id   IS NOT NULL THEN 1 ELSE 0 END
   + CASE WHEN sdx.sd_event_id  IS NOT NULL THEN 1 ELSE 0 END
   + CASE WHEN sgx.sg_event_id  IS NOT NULL THEN 1 ELSE 0 END) AS sources_count,
  -- Compact JSON of all external ids (for API responses)
  jsonb_build_object(
    'espn',     CASE WHEN ex.espn_event_id   IS NOT NULL THEN
                  jsonb_build_object('event_id', ex.espn_event_id, 'league', ex.espn_league, 'slug', ex.espn_slug)
                ELSE NULL END,
    'seatdata', CASE WHEN sdx.sd_event_id    IS NOT NULL THEN
                  jsonb_build_object('event_id', sdx.sd_event_id, 'match_method', sdx.match_method)
                ELSE NULL END,
    'seatgeek', CASE WHEN sgx.sg_event_id    IS NOT NULL THEN
                  jsonb_build_object('event_id', sgx.sg_event_id, 'name', sgx.sg_event_name,
                                     'location', sgx.sg_event_location, 'match_method', sgx.match_method)
                ELSE NULL END
  ) AS external_ids
FROM events e
LEFT JOIN event_xref           ex  ON ex.tevo_event_id  = e.id
LEFT JOIN seatdata_event_xref  sdx ON sdx.tevo_event_id = e.id
LEFT JOIN seatgeek_event_xref  sgx ON sgx.tevo_event_id = e.id
LEFT JOIN event_lifecycle      lc  ON lc.event_id       = e.id;

GRANT SELECT ON public.entity_event_map TO authenticated, service_role;

-- ============================================================
-- C. Entity performer map — TEvo performer ↔ all sources
-- ============================================================
-- TEvo doesn't expose a `performers` table; the performer is a (id, name)
-- pair on the events table. We pull DISTINCT (performer_id, name) and
-- LEFT JOIN to the xrefs.

CREATE OR REPLACE VIEW public.entity_performer_map AS
WITH tevo_performers AS (
  SELECT DISTINCT primary_performer_id AS tevo_performer_id, primary_performer_name AS name
  FROM events WHERE primary_performer_id IS NOT NULL
)
SELECT
  tp.tevo_performer_id,
  tp.name                                  AS tevo_performer_name,
  -- Performer metadata (TEvo-derived)
  pm.what_event_type, pm.top_category_name, pm.parent_category_name,
  pm.category_name, pm.genre,
  -- ESPN (via performer_external_ids source='espn')
  pei.external_id                          AS espn_team_id,
  pei.league                               AS espn_league,
  -- Home venues (sports only)
  (SELECT array_agg(DISTINCT phv.venue_id)
     FROM performer_home_venues phv WHERE phv.performer_id = tp.tevo_performer_id) AS home_venue_ids,
  -- SeatData
  sdpx.sd_std_event_id                     AS sd_performer_id,
  -- SeatGeek (just the name string we matched; SG broker-API doesn't expose perf_id directly)
  sgpx.sg_performer_name                   AS sg_performer_name,
  sgpx.match_method                        AS sg_match_method,
  -- Coverage
  (CASE WHEN pei.external_id        IS NOT NULL THEN 1 ELSE 0 END
   + CASE WHEN sdpx.sd_std_event_id IS NOT NULL THEN 1 ELSE 0 END
   + CASE WHEN sgpx.sg_performer_name IS NOT NULL THEN 1 ELSE 0 END) AS sources_count,
  jsonb_build_object(
    'espn',     CASE WHEN pei.external_id IS NOT NULL THEN
                  jsonb_build_object('team_id', pei.external_id, 'league', pei.league)
                ELSE NULL END,
    'seatdata', CASE WHEN sdpx.sd_std_event_id IS NOT NULL THEN
                  jsonb_build_object('std_event_id', sdpx.sd_std_event_id)
                ELSE NULL END,
    'seatgeek', CASE WHEN sgpx.sg_performer_name IS NOT NULL THEN
                  jsonb_build_object('name', sgpx.sg_performer_name, 'match_method', sgpx.match_method)
                ELSE NULL END
  ) AS external_ids
FROM tevo_performers tp
LEFT JOIN performer_metadata        pm   ON pm.performer_id     = tp.tevo_performer_id
LEFT JOIN performer_external_ids    pei  ON pei.performer_id    = tp.tevo_performer_id AND pei.source = 'espn'
LEFT JOIN seatdata_performer_xref   sdpx ON sdpx.tevo_performer_id = tp.tevo_performer_id
LEFT JOIN seatgeek_performer_xref   sgpx ON sgpx.tevo_performer_id = tp.tevo_performer_id;

GRANT SELECT ON public.entity_performer_map TO authenticated, service_role;

-- ============================================================
-- D. Entity venue map — TEvo venue ↔ all sources
-- ============================================================
-- TEvo also doesn't have a `venues` table; venue lives on events too.
-- ESPN doesn't expose venue ids cleanly so we don't xref ESPN venues.

CREATE OR REPLACE VIEW public.entity_venue_map AS
WITH tevo_venues AS (
  SELECT DISTINCT venue_id AS tevo_venue_id, venue_name AS name, venue_location
  FROM events WHERE venue_id IS NOT NULL
)
SELECT
  tv.tevo_venue_id,
  tv.name                                  AS tevo_venue_name,
  tv.venue_location                        AS tevo_venue_location,
  -- SeatData
  sdvx.sd_std_venue_id                     AS sd_venue_id,
  sdvx.sd_venue_name                       AS sd_venue_name,
  sdvx.sd_venue_slug                       AS sd_venue_slug,
  sdvx.sd_venue_city                       AS sd_venue_city,
  sdvx.sd_venue_state                      AS sd_venue_state,
  -- SeatGeek
  sgvx.sg_venue_name                       AS sg_venue_name,
  sgvx.match_method                        AS sg_match_method,
  -- (ESPN doesn't expose venue ids)
  -- Coverage
  (CASE WHEN sdvx.sd_std_venue_id IS NOT NULL THEN 1 ELSE 0 END
   + CASE WHEN sgvx.sg_venue_name  IS NOT NULL THEN 1 ELSE 0 END) AS sources_count,
  jsonb_build_object(
    'seatdata', CASE WHEN sdvx.sd_std_venue_id IS NOT NULL THEN
                  jsonb_build_object('venue_id', sdvx.sd_std_venue_id, 'name', sdvx.sd_venue_name,
                                     'slug', sdvx.sd_venue_slug, 'city', sdvx.sd_venue_city,
                                     'state', sdvx.sd_venue_state)
                ELSE NULL END,
    'seatgeek', CASE WHEN sgvx.sg_venue_name IS NOT NULL THEN
                  jsonb_build_object('name', sgvx.sg_venue_name, 'match_method', sgvx.match_method)
                ELSE NULL END
  ) AS external_ids
FROM tevo_venues tv
LEFT JOIN seatdata_venue_xref  sdvx ON sdvx.tevo_venue_id = tv.tevo_venue_id
LEFT JOIN seatgeek_venue_xref  sgvx ON sgvx.tevo_venue_id = tv.tevo_venue_id;

GRANT SELECT ON public.entity_venue_map TO authenticated, service_role;

-- ============================================================
-- E. Coverage diagnostic view — how many of each entity type are
--    matched per source. Drives backfill prioritization.
-- ============================================================
CREATE OR REPLACE VIEW public.cross_source_coverage AS
SELECT 'event' AS entity_type,
       (SELECT COUNT(*) FROM events)                                       AS total,
       (SELECT COUNT(*) FROM event_xref)                                  AS espn_linked,
       (SELECT COUNT(*) FROM seatdata_event_xref)                         AS seatdata_linked,
       (SELECT COUNT(*) FROM seatgeek_event_xref)                         AS seatgeek_linked,
       (SELECT COUNT(*) FROM entity_event_map WHERE sources_count >= 2)   AS multi_source_linked
UNION ALL
SELECT 'performer',
       (SELECT COUNT(DISTINCT primary_performer_id) FROM events WHERE primary_performer_id IS NOT NULL),
       (SELECT COUNT(*) FROM performer_external_ids WHERE source = 'espn'),
       (SELECT COUNT(*) FROM seatdata_performer_xref),
       (SELECT COUNT(*) FROM seatgeek_performer_xref),
       (SELECT COUNT(*) FROM entity_performer_map WHERE sources_count >= 2)
UNION ALL
SELECT 'venue',
       (SELECT COUNT(DISTINCT venue_id) FROM events WHERE venue_id IS NOT NULL),
       NULL,
       (SELECT COUNT(*) FROM seatdata_venue_xref),
       (SELECT COUNT(*) FROM seatgeek_venue_xref),
       (SELECT COUNT(*) FROM entity_venue_map WHERE sources_count >= 2);

GRANT SELECT ON public.cross_source_coverage TO authenticated, service_role;

-- ============================================================
-- F. Translation functions — given any source's id, return TEvo id
-- ============================================================

CREATE OR REPLACE FUNCTION public.tevo_event_id_for(p_source text, p_external_id text)
RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE v_id bigint;
BEGIN
  IF lower(p_source) = 'espn' THEN
    SELECT tevo_event_id INTO v_id FROM event_xref WHERE espn_event_id = p_external_id LIMIT 1;
  ELSIF lower(p_source) = 'seatdata' THEN
    SELECT tevo_event_id INTO v_id FROM seatdata_event_xref WHERE sd_event_id::text = p_external_id LIMIT 1;
  ELSIF lower(p_source) = 'seatgeek' THEN
    SELECT tevo_event_id INTO v_id FROM seatgeek_event_xref WHERE sg_event_id::text = p_external_id LIMIT 1;
  ELSE
    RAISE EXCEPTION 'unknown source %, valid: espn | seatdata | seatgeek', p_source;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.tevo_performer_id_for(p_source text, p_external_id text)
RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE v_id bigint;
BEGIN
  IF lower(p_source) = 'espn' THEN
    -- ESPN team_id is league-scoped; caller can pass 'NBA:18' to disambiguate
    IF p_external_id LIKE '%:%' THEN
      SELECT performer_id INTO v_id FROM performer_external_ids
       WHERE source = 'espn' AND league = split_part(p_external_id, ':', 1)
         AND external_id = split_part(p_external_id, ':', 2) LIMIT 1;
    ELSE
      -- ambiguous; first match wins
      SELECT performer_id INTO v_id FROM performer_external_ids
       WHERE source = 'espn' AND external_id = p_external_id LIMIT 1;
    END IF;
  ELSIF lower(p_source) = 'seatdata' THEN
    SELECT tevo_performer_id INTO v_id FROM seatdata_performer_xref
     WHERE sd_std_event_id::text = p_external_id LIMIT 1;
  ELSIF lower(p_source) = 'seatgeek' THEN
    -- SG matches by name string (broker API has no performer_id)
    SELECT tevo_performer_id INTO v_id FROM seatgeek_performer_xref
     WHERE sg_performer_name = p_external_id LIMIT 1;
  ELSE
    RAISE EXCEPTION 'unknown source %, valid: espn | seatdata | seatgeek', p_source;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.tevo_venue_id_for(p_source text, p_external_id text)
RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE v_id bigint;
BEGIN
  IF lower(p_source) = 'seatdata' THEN
    SELECT tevo_venue_id INTO v_id FROM seatdata_venue_xref
     WHERE sd_std_venue_id::text = p_external_id LIMIT 1;
  ELSIF lower(p_source) = 'seatgeek' THEN
    SELECT tevo_venue_id INTO v_id FROM seatgeek_venue_xref
     WHERE sg_venue_name = p_external_id LIMIT 1;
  ELSE
    RAISE EXCEPTION 'unknown source % (espn does not expose venue ids), valid: seatdata | seatgeek', p_source;
  END IF;
  RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION public.tevo_event_id_for(text, text)     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tevo_performer_id_for(text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tevo_venue_id_for(text, text)     TO authenticated, service_role;

-- Convenience inverse helpers (TEvo id → all external ids as JSON)
CREATE OR REPLACE FUNCTION public.external_ids_for_event(p_tevo_event_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT external_ids FROM entity_event_map WHERE tevo_event_id = p_tevo_event_id LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.external_ids_for_performer(p_tevo_performer_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT external_ids FROM entity_performer_map WHERE tevo_performer_id = p_tevo_performer_id LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.external_ids_for_venue(p_tevo_venue_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT external_ids FROM entity_venue_map WHERE tevo_venue_id = p_tevo_venue_id LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.external_ids_for_event(bigint)     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.external_ids_for_performer(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.external_ids_for_venue(bigint)     TO authenticated, service_role;

COMMIT;
