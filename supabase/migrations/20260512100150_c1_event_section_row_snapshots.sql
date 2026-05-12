-- Migration 20260512100150 · level:supervisor · lane:canonical · writes:event_section_row_snapshots,rollup_event_section_row · reads:listings_snapshots,events,_sec_norm · pre:20260512100000

CREATE TABLE IF NOT EXISTS event_section_row_snapshots (
  event_id        bigint      NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  source          text        NOT NULL CHECK (source IN ('tevo','seatgeek','seatdata')),
  captured_at     timestamptz NOT NULL,
  section_norm    text        NOT NULL,
  row             text        NOT NULL,
  quantity        int         NOT NULL,
  listings_count  int         NOT NULL,
  min_price       numeric(10,2),
  median_price    numeric(10,2),
  max_price       numeric(10,2),
  owned_quantity  int         NOT NULL DEFAULT 0,
  content_hash    text        NOT NULL,
  meta            jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, source, captured_at, section_norm, row)
);

CREATE INDEX IF NOT EXISTS esrs_event_section_row_idx
  ON event_section_row_snapshots (event_id, section_norm, row, captured_at DESC);
CREATE INDEX IF NOT EXISTS esrs_captured_idx
  ON event_section_row_snapshots (captured_at DESC);

CREATE TRIGGER event_section_row_snapshots_updated_at
  BEFORE UPDATE ON event_section_row_snapshots
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

COMMENT ON TABLE event_section_row_snapshots IS
  'Per-event-per-snapshot rollup at (source, section_norm, row, quantity) grain. Source-tagged. Change-only via content_hash. Driven by TEvo listings_snapshots and (future) SG listings.';

ALTER TABLE event_section_row_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY esrs_service_all ON event_section_row_snapshots
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY esrs_readonly_select ON event_section_row_snapshots
  FOR SELECT TO coworker_readonly USING (true);

-- Backfill helper: rolls up one event's latest captured_at from listings_snapshots
CREATE OR REPLACE FUNCTION rollup_event_section_row(p_event_id bigint, p_captured_at timestamptz DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamptz;
  v_n  int;
BEGIN
  IF p_captured_at IS NULL THEN
    SELECT MAX(captured_at) INTO v_ts FROM listings_snapshots WHERE event_id = p_event_id;
  ELSE
    v_ts := p_captured_at;
  END IF;
  IF v_ts IS NULL THEN RETURN 0; END IF;

  WITH src AS (
    SELECT
      event_id,
      'tevo'::text AS source,
      v_ts AS captured_at,
      _sec_norm(section) AS section_norm,
      row,
      SUM(quantity)::int AS quantity,
      COUNT(*)::int AS listings_count,
      MIN(retail_price) AS min_price,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price) AS median_price,
      MAX(retail_price) AS max_price,
      COALESCE(SUM(quantity) FILTER (WHERE is_owned), 0)::int AS owned_quantity
    FROM listings_snapshots
    WHERE event_id = p_event_id AND captured_at = v_ts AND NOT is_ancillary
      AND section IS NOT NULL AND row IS NOT NULL
    GROUP BY event_id, _sec_norm(section), row
  )
  INSERT INTO event_section_row_snapshots (
    event_id, source, captured_at, section_norm, row, quantity, listings_count,
    min_price, median_price, max_price, owned_quantity, content_hash
  )
  SELECT
    event_id, source, captured_at, section_norm, row, quantity, listings_count,
    min_price, median_price, max_price, owned_quantity,
    md5(quantity::text || '|' || listings_count::text || '|' ||
        COALESCE(median_price::text,'') || '|' || owned_quantity::text)
  FROM src
  ON CONFLICT (event_id, source, captured_at, section_norm, row) DO NOTHING;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

COMMENT ON FUNCTION rollup_event_section_row(bigint, timestamptz) IS
  'Rolls up (section_norm, row) for a single event from listings_snapshots. Pass captured_at=NULL to use latest snapshot. Idempotent via ON CONFLICT DO NOTHING.';
