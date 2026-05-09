-- ============================================================================
-- Migration 20260509190000 — SeatGeek historic sales fabric
--
-- Turns 400 raw seatgeek_orders rows (2018 → 2025-06) into structured
-- historic data:
--   - performer extraction from sg_event_name (home + away for sports;
--     headliner for concerts/comedy)
--   - season label + season type (regular / postseason / preseason)
--   - section kind canonicalization (numeric / alpha-prefix / GA / ...)
--   - cross-walk extracted SG performer names to performer_metadata
--
-- Read-only — no SG calls. RULE 2 preserved.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- (1) Performer extractor
CREATE OR REPLACE FUNCTION sg_extract_performers(p_name text)
RETURNS text[] AS $$
DECLARE
  v_clean text;
  v_match text[];
BEGIN
  IF p_name IS NULL OR length(p_name) = 0 THEN RETURN ARRAY[]::text[]; END IF;
  v_clean := p_name;
  v_clean := regexp_replace(v_clean, '^Parking ', '', 'i');
  v_clean := regexp_replace(v_clean, ' Parking$', '', 'i');
  v_clean := regexp_replace(v_clean, ' \(.*?\)$', '');
  v_clean := regexp_replace(v_clean, ' Football$', '', 'i');
  v_clean := regexp_replace(v_clean, ' Basketball$', '', 'i');
  v_clean := regexp_replace(v_clean, ' Baseball$', '', 'i');
  v_clean := regexp_replace(v_clean, ' Hockey$', '', 'i');

  v_match := regexp_match(v_clean, '^(.+?) (?:at|vs\.?|@) (.+?)$', 'i');
  IF v_match IS NOT NULL THEN
    RETURN ARRAY[trim(v_match[1]), trim(v_match[2])];
  END IF;

  v_match := regexp_match(v_clean, '^(.+?) (?:with|feat\.?|featuring|w/) ', 'i');
  IF v_match IS NOT NULL THEN
    RETURN ARRAY[trim(v_match[1])];
  END IF;

  v_match := regexp_match(v_clean, '^(.+?) (?:&|and) (.+?)$');
  IF v_match IS NOT NULL THEN
    RETURN ARRAY[trim(v_match[1]), trim(v_match[2])];
  END IF;

  RETURN ARRAY[trim(v_clean)];
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (2) Season + season-type derivers
CREATE OR REPLACE FUNCTION sg_derive_season_label(p_category text, p_date date)
RETURNS text AS $$
DECLARE y int; m int;
BEGIN
  IF p_date IS NULL THEN RETURN NULL; END IF;
  y := extract(year FROM p_date); m := extract(month FROM p_date);
  CASE lower(coalesce(p_category, ''))
    WHEN 'mlb'  THEN RETURN 'MLB '  || y;
    WHEN 'wnba' THEN RETURN 'WNBA ' || y;
    WHEN 'mls'  THEN RETURN 'MLS '  || y;
    WHEN 'nba'  THEN
      IF m >= 10 THEN RETURN 'NBA ' || y     || '-' || lpad(((y+1) % 100)::text, 2, '0');
      ELSE             RETURN 'NBA ' || (y-1) || '-' || lpad((y % 100)::text, 2, '0');
      END IF;
    WHEN 'nhl' THEN
      IF m >= 10 THEN RETURN 'NHL ' || y     || '-' || lpad(((y+1) % 100)::text, 2, '0');
      ELSE             RETURN 'NHL ' || (y-1) || '-' || lpad((y % 100)::text, 2, '0');
      END IF;
    WHEN 'nfl' THEN
      IF m >= 8 THEN RETURN 'NFL ' || y;
      ELSE            RETURN 'NFL ' || (y-1);
      END IF;
    WHEN 'ncaa_football' THEN
      IF m >= 8 THEN RETURN 'NCAA-FB ' || y;
      ELSE            RETURN 'NCAA-FB ' || (y-1);
      END IF;
    WHEN 'ncaa_basketball' THEN
      IF m >= 11 THEN RETURN 'NCAA-MBB ' || y     || '-' || lpad(((y+1) % 100)::text, 2, '0');
      ELSE             RETURN 'NCAA-MBB ' || (y-1) || '-' || lpad((y % 100)::text, 2, '0');
      END IF;
    ELSE RETURN initcap(coalesce(p_category, 'Event'));
  END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION sg_derive_season_type(p_category text, p_date date)
RETURNS text AS $$
DECLARE m int;
BEGIN
  IF p_date IS NULL THEN RETURN NULL; END IF;
  m := extract(month FROM p_date);
  CASE lower(coalesce(p_category, ''))
    WHEN 'mlb' THEN
      IF m IN (3) THEN RETURN 'spring_training';
      ELSIF m IN (10) AND extract(day FROM p_date) >= 1 THEN RETURN 'postseason';
      ELSIF m IN (11) THEN RETURN 'postseason';
      ELSE RETURN 'regular';
      END IF;
    WHEN 'nba', 'nhl' THEN
      IF m IN (10) THEN RETURN 'preseason_or_regular_open';
      ELSIF m IN (4) AND extract(day FROM p_date) >= 16 THEN RETURN 'playoffs';
      ELSIF m IN (5,6) THEN RETURN 'playoffs';
      ELSE RETURN 'regular';
      END IF;
    WHEN 'nfl' THEN
      IF m IN (8) THEN RETURN 'preseason';
      ELSIF m IN (1,2) THEN RETURN 'playoffs';
      ELSE RETURN 'regular';
      END IF;
    WHEN 'wnba' THEN
      IF m IN (5) THEN RETURN 'preseason_or_regular_open';
      ELSIF m IN (9,10) THEN RETURN 'playoffs';
      ELSE RETURN 'regular';
      END IF;
    WHEN 'mls' THEN
      IF m IN (10,11,12) THEN RETURN 'playoffs_or_late';
      ELSE RETURN 'regular';
      END IF;
    ELSE RETURN NULL;
  END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (3) Section canonicalization
CREATE OR REPLACE FUNCTION sg_section_kind(p_section text)
RETURNS text AS $$
BEGIN
  IF p_section IS NULL OR length(p_section) = 0 THEN RETURN 'unknown'; END IF;
  IF p_section ~* '^(GA|GENERAL ADMISSION|RESERVED|FEUERZONE|PIT|FLOOR|LAWN)$' THEN RETURN 'GA'; END IF;
  IF p_section ~ '^[0-9]+$' THEN RETURN 'numeric'; END IF;
  IF p_section ~ '^[A-Z]{1,4}[0-9]+$' THEN RETURN 'alpha_prefix_numeric'; END IF;
  IF p_section ~ '^[A-Z]{1,4}$' THEN RETURN 'alpha_only'; END IF;
  RETURN 'mixed';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION sg_section_prefix(p_section text)
RETURNS text AS $$
DECLARE m text[];
BEGIN
  m := regexp_match(coalesce(p_section, ''), '^([A-Z]{1,4})[0-9]+$');
  RETURN m[1];
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION sg_section_number(p_section text)
RETURNS int AS $$
DECLARE m text[];
BEGIN
  m := regexp_match(coalesce(p_section, ''), '([0-9]+)');
  RETURN m[1]::int;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (4) Materialized historic-sales table
CREATE TABLE IF NOT EXISTS seatgeek_historic_sales (
  id                          bigserial PRIMARY KEY,
  sg_order_row_id             bigint NOT NULL UNIQUE REFERENCES seatgeek_orders(id) ON DELETE CASCADE,
  sg_event_id                 bigint,
  sg_event_name               text,
  sg_event_date               date,
  sg_venue                    text,
  sg_category                 text,
  performer_away              text,
  performer_home              text,
  performer_headliner         text,
  performer_support           text,
  performer_count             int,
  tevo_performer_id_away      bigint,
  tevo_performer_id_home      bigint,
  tevo_performer_id_headliner bigint,
  season_label                text,
  season_type                 text,
  event_year                  int,
  event_month                 int,
  event_dow                   int,
  section_kind                text,
  section_prefix              text,
  section_number              int,
  section_raw                 text,
  row_raw                     text,
  sale_quantity               int,
  sale_price                  numeric,
  sale_total                  numeric,
  status                      text,
  derived_at                  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS shs_sg_event_idx ON seatgeek_historic_sales(sg_event_id);
CREATE INDEX IF NOT EXISTS shs_season_idx ON seatgeek_historic_sales(season_label, season_type);
CREATE INDEX IF NOT EXISTS shs_perf_home_idx ON seatgeek_historic_sales(performer_home);
CREATE INDEX IF NOT EXISTS shs_perf_away_idx ON seatgeek_historic_sales(performer_away);
CREATE INDEX IF NOT EXISTS shs_perf_headliner_idx ON seatgeek_historic_sales(performer_headliner);
CREATE INDEX IF NOT EXISTS shs_section_kind_idx ON seatgeek_historic_sales(section_kind);
CREATE INDEX IF NOT EXISTS shs_tevo_away_idx ON seatgeek_historic_sales(tevo_performer_id_away)
  WHERE tevo_performer_id_away IS NOT NULL;
CREATE INDEX IF NOT EXISTS shs_tevo_home_idx ON seatgeek_historic_sales(tevo_performer_id_home)
  WHERE tevo_performer_id_home IS NOT NULL;
CREATE INDEX IF NOT EXISTS shs_tevo_head_idx ON seatgeek_historic_sales(tevo_performer_id_headliner)
  WHERE tevo_performer_id_headliner IS NOT NULL;

-- (5) Performer-name resolver
CREATE OR REPLACE FUNCTION resolve_tevo_performer_id(p_name text, p_min_sim numeric DEFAULT 0.45)
RETURNS bigint AS $$
DECLARE v_id bigint; v_clean text;
BEGIN
  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN RETURN NULL; END IF;
  v_clean := lower(trim(p_name));
  SELECT performer_id INTO v_id
  FROM performer_metadata WHERE lower(trim(name)) = v_clean LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  SELECT performer_id INTO v_id
  FROM performer_metadata
  WHERE similarity(lower(name), v_clean) >= p_min_sim
  ORDER BY similarity(lower(name), v_clean) DESC LIMIT 1;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- (6) Populate function — full rebuild
CREATE OR REPLACE FUNCTION populate_seatgeek_historic_sales()
RETURNS jsonb AS $$
DECLARE v_inserted int; v_updated int; v_perf_xrefs int; v_tevo_matches int;
BEGIN
  WITH parsed AS (
    SELECT so.id AS sg_order_row_id, so.sg_event_id, so.sg_event_name,
           so.sg_event_date, so.sg_venue, sgc.sg_category,
           sg_extract_performers(so.sg_event_name) AS performers,
           so.sale_quantity, so.sale_price, so.payment_total, so.status,
           so.sale_section, so.sale_row
    FROM seatgeek_orders so
    LEFT JOIN sg_events_canonical sgc ON sgc.sg_event_id = so.sg_event_id
  ),
  shaped AS (
    SELECT p.*,
      CASE WHEN p.sg_event_name ~* ' (at|vs\.?|@) ' THEN p.performers[1] END AS performer_away,
      CASE WHEN p.sg_event_name ~* ' (at|vs\.?|@) ' THEN p.performers[2] END AS performer_home,
      CASE WHEN p.sg_event_name !~* ' (at|vs\.?|@) ' THEN p.performers[1] END AS performer_headliner,
      CASE WHEN p.sg_event_name !~* ' (at|vs\.?|@) ' THEN p.performers[2] END AS performer_support
    FROM parsed p
  ),
  upserted AS (
    INSERT INTO seatgeek_historic_sales (
      sg_order_row_id, sg_event_id, sg_event_name, sg_event_date, sg_venue, sg_category,
      performer_away, performer_home, performer_headliner, performer_support, performer_count,
      tevo_performer_id_away, tevo_performer_id_home, tevo_performer_id_headliner,
      season_label, season_type, event_year, event_month, event_dow,
      section_kind, section_prefix, section_number, section_raw, row_raw,
      sale_quantity, sale_price, sale_total, status, derived_at
    )
    SELECT sg_order_row_id, sg_event_id, sg_event_name, sg_event_date, sg_venue, sg_category,
           performer_away, performer_home, performer_headliner, performer_support,
           coalesce(array_length(performers,1), 0),
           resolve_tevo_performer_id(performer_away),
           resolve_tevo_performer_id(performer_home),
           resolve_tevo_performer_id(performer_headliner),
           sg_derive_season_label(sg_category, sg_event_date),
           sg_derive_season_type(sg_category, sg_event_date),
           extract(year  FROM sg_event_date)::int,
           extract(month FROM sg_event_date)::int,
           extract(dow   FROM sg_event_date)::int,
           sg_section_kind(sale_section),
           sg_section_prefix(sale_section),
           sg_section_number(sale_section),
           sale_section, sale_row,
           sale_quantity, sale_price, payment_total, status, now()
    FROM shaped
    ON CONFLICT (sg_order_row_id) DO UPDATE SET
      sg_event_name = EXCLUDED.sg_event_name, sg_event_date = EXCLUDED.sg_event_date,
      sg_venue = EXCLUDED.sg_venue, sg_category = EXCLUDED.sg_category,
      performer_away = EXCLUDED.performer_away, performer_home = EXCLUDED.performer_home,
      performer_headliner = EXCLUDED.performer_headliner, performer_support = EXCLUDED.performer_support,
      performer_count = EXCLUDED.performer_count,
      tevo_performer_id_away = EXCLUDED.tevo_performer_id_away,
      tevo_performer_id_home = EXCLUDED.tevo_performer_id_home,
      tevo_performer_id_headliner = EXCLUDED.tevo_performer_id_headliner,
      season_label = EXCLUDED.season_label, season_type = EXCLUDED.season_type,
      event_year = EXCLUDED.event_year, event_month = EXCLUDED.event_month, event_dow = EXCLUDED.event_dow,
      section_kind = EXCLUDED.section_kind, section_prefix = EXCLUDED.section_prefix,
      section_number = EXCLUDED.section_number, section_raw = EXCLUDED.section_raw, row_raw = EXCLUDED.row_raw,
      sale_quantity = EXCLUDED.sale_quantity, sale_price = EXCLUDED.sale_price,
      sale_total = EXCLUDED.sale_total, status = EXCLUDED.status, derived_at = now()
    RETURNING (xmax = 0) AS is_insert
  )
  SELECT count(*) FILTER (WHERE is_insert),
         count(*) FILTER (WHERE NOT is_insert)
  INTO v_inserted, v_updated FROM upserted;

  WITH distinct_xrefs AS (
    SELECT DISTINCT sg_perf_name, tevo_id FROM (
      SELECT performer_away    AS sg_perf_name, tevo_performer_id_away    AS tevo_id FROM seatgeek_historic_sales
      UNION ALL
      SELECT performer_home,    tevo_performer_id_home    FROM seatgeek_historic_sales
      UNION ALL
      SELECT performer_headliner, tevo_performer_id_headliner FROM seatgeek_historic_sales
    ) AS x
    WHERE sg_perf_name IS NOT NULL AND tevo_id IS NOT NULL
  ),
  inserted_xrefs AS (
    INSERT INTO seatgeek_performer_xref (tevo_performer_id, sg_performer_name,
                                          match_method, match_confidence, matched_at)
    SELECT tevo_id, sg_perf_name, 'historic_sales_extractor', 0.85, now()
    FROM distinct_xrefs
    ON CONFLICT (tevo_performer_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_perf_xrefs FROM inserted_xrefs;

  SELECT count(*) INTO v_tevo_matches FROM seatgeek_historic_sales
  WHERE tevo_performer_id_away IS NOT NULL
     OR tevo_performer_id_home IS NOT NULL
     OR tevo_performer_id_headliner IS NOT NULL;

  RETURN jsonb_build_object(
    'rows_inserted', v_inserted, 'rows_updated', v_updated,
    'new_perf_xrefs', v_perf_xrefs,
    'rows_with_any_tevo_match', v_tevo_matches,
    'total_rows', (SELECT count(*) FROM seatgeek_historic_sales),
    'ran_at', now()
  );
END;
$$ LANGUAGE plpgsql;

-- (7) sg_category backfill from matched performer espn_league
CREATE OR REPLACE FUNCTION infer_sg_category_from_performers()
RETURNS int AS $$
DECLARE v_count int;
BEGIN
  WITH inferred AS (
    SELECT sgc.sg_event_id,
      (SELECT lower(replace(pm.espn_league, '-', '_'))
       FROM performer_metadata pm
       WHERE pm.performer_id IN (
         SELECT tevo_performer_id_home FROM seatgeek_historic_sales
           WHERE sg_event_id = sgc.sg_event_id AND tevo_performer_id_home IS NOT NULL
         UNION ALL
         SELECT tevo_performer_id_away FROM seatgeek_historic_sales
           WHERE sg_event_id = sgc.sg_event_id AND tevo_performer_id_away IS NOT NULL
       )
       AND pm.espn_league IS NOT NULL
       GROUP BY pm.espn_league ORDER BY count(*) DESC LIMIT 1) AS inferred_category
    FROM sg_events_canonical sgc WHERE sgc.sg_category IS NULL
  )
  UPDATE sg_events_canonical sgc
  SET sg_category = CASE i.inferred_category
                      WHEN 'ncaaf' THEN 'ncaa_football'
                      WHEN 'ncaa'  THEN 'ncaa_basketball'
                      ELSE i.inferred_category
                    END,
      updated_at = now()
  FROM inferred i
  WHERE sgc.sg_event_id = i.sg_event_id AND i.inferred_category IS NOT NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- (8) Schedule a daily refresh — picks up new orders + re-scores against
-- updated performer_metadata / sg_events_canonical state.
SELECT cron.schedule(
  'seatgeek_historic_sales_daily',
  '15 5 * * *',  -- daily at 05:15 UTC
  $$ SELECT infer_sg_category_from_performers();
     SELECT populate_seatgeek_historic_sales(); $$
);
