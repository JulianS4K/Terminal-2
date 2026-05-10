-- ============================================================================
-- Phase 6: audit views + audit_cross_source_health() RPC.
--
-- Drift detection has three pillars:
--   1. v_canonical_coverage_v2  — how many tevo entities are linked per source
--   2. v_canonical_drift        — rows in xref tables not yet in the registry
--   3. v_orphan_*_data          — source data rows still missing tevo_event_id
--   4. v_event_overlay_summary  — per-event count of date/venue overlays
--
-- The RPC bundles them into a single jsonb snapshot, suitable for cron logging.
-- ============================================================================

DROP VIEW IF EXISTS v_canonical_coverage_v2 CASCADE;
CREATE VIEW v_canonical_coverage_v2 AS
WITH event_universe AS (
  SELECT id AS tevo_id FROM events
), venue_universe AS (
  SELECT DISTINCT venue_id AS tevo_id FROM events WHERE venue_id IS NOT NULL
), performer_universe AS (
  SELECT DISTINCT primary_performer_id AS tevo_id FROM events WHERE primary_performer_id IS NOT NULL
)
SELECT 'event'::text AS entity_kind,
       (SELECT COUNT(*) FROM event_universe) AS tevo_total,
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='espn')      AS with_espn,
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='sg_broker') AS with_seatgeek,
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='seatdata')  AS with_seatdata,
       0::bigint AS with_wikipedia,
       (SELECT COUNT(*) FROM (
          SELECT tevo_id FROM canonical_external_ids
           WHERE entity_kind='event'
           GROUP BY tevo_id HAVING COUNT(DISTINCT source_key) >= 2) x) AS with_2plus_sources
  FROM canonical_external_ids
 WHERE entity_kind='event'
UNION ALL
SELECT 'venue',
       (SELECT COUNT(*) FROM venue_universe),
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='espn'),
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='sg_broker'),
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='seatdata'),
       0::bigint,
       (SELECT COUNT(*) FROM (
          SELECT tevo_id FROM canonical_external_ids
           WHERE entity_kind='venue'
           GROUP BY tevo_id HAVING COUNT(DISTINCT source_key) >= 2) x)
  FROM canonical_external_ids
 WHERE entity_kind='venue'
UNION ALL
SELECT 'performer',
       (SELECT COUNT(*) FROM performer_universe),
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key IN ('espn','espn_team')),
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='sg_broker'),
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='seatdata'),
       COUNT(DISTINCT tevo_id) FILTER (WHERE source_key='wikipedia'),
       (SELECT COUNT(*) FROM (
          SELECT tevo_id FROM canonical_external_ids
           WHERE entity_kind='performer'
           GROUP BY tevo_id HAVING COUNT(DISTINCT source_key) >= 2) x)
  FROM canonical_external_ids
 WHERE entity_kind='performer';

DROP VIEW IF EXISTS v_canonical_drift CASCADE;
CREATE VIEW v_canonical_drift AS
SELECT 'event_xref'::text AS xref_table, e.tevo_event_id::text AS tevo_id,
       'espn'::text AS expected_source, 'missing_from_canonical'::text AS issue
  FROM event_xref e
  LEFT JOIN canonical_external_ids c
    ON c.entity_kind='event' AND c.tevo_id=e.tevo_event_id AND c.source_key='espn'
 WHERE c.tevo_id IS NULL
UNION ALL
SELECT 'seatgeek_event_xref', s.tevo_event_id::text, 'sg_broker', 'missing_from_canonical'
  FROM seatgeek_event_xref s
  LEFT JOIN canonical_external_ids c
    ON c.entity_kind='event' AND c.tevo_id=s.tevo_event_id AND c.source_key='sg_broker'
 WHERE c.tevo_id IS NULL
UNION ALL
SELECT 'seatdata_event_xref', s.tevo_event_id::text, 'seatdata', 'missing_from_canonical'
  FROM seatdata_event_xref s
  LEFT JOIN canonical_external_ids c
    ON c.entity_kind='event' AND c.tevo_id=s.tevo_event_id AND c.source_key='seatdata'
 WHERE c.tevo_id IS NULL
UNION ALL
SELECT 'seatgeek_venue_xref', v.tevo_venue_id::text, 'sg_broker', 'missing_from_canonical'
  FROM seatgeek_venue_xref v
  LEFT JOIN canonical_external_ids c
    ON c.entity_kind='venue' AND c.tevo_id=v.tevo_venue_id AND c.source_key='sg_broker'
 WHERE c.tevo_id IS NULL
UNION ALL
SELECT 'seatdata_venue_xref', v.tevo_venue_id::text, 'seatdata', 'missing_from_canonical'
  FROM seatdata_venue_xref v
  LEFT JOIN canonical_external_ids c
    ON c.entity_kind='venue' AND c.tevo_id=v.tevo_venue_id AND c.source_key='seatdata'
 WHERE c.tevo_id IS NULL
UNION ALL
SELECT 'venue_assets', va.tevo_venue_id::text, 'espn', 'missing_from_canonical'
  FROM venue_assets va
  LEFT JOIN canonical_external_ids c
    ON c.entity_kind='venue' AND c.tevo_id=va.tevo_venue_id AND c.source_key='espn'
 WHERE va.espn_venue_id IS NOT NULL AND c.tevo_id IS NULL
UNION ALL
SELECT 'performer_external_ids', p.performer_id::text, p.source, 'missing_from_canonical'
  FROM performer_external_ids p
  LEFT JOIN canonical_external_ids c
    ON c.entity_kind='performer' AND c.tevo_id=p.performer_id AND c.source_key=p.source
 WHERE c.tevo_id IS NULL
UNION ALL
SELECT 'sg_events_canonical', sc.sg_event_id::text, 'sg_broker', 'matched_but_no_xref'
  FROM sg_events_canonical sc
  LEFT JOIN seatgeek_event_xref x ON x.tevo_event_id = sc.tevo_event_id
 WHERE sc.tevo_event_id IS NOT NULL AND x.tevo_event_id IS NULL;

DROP VIEW IF EXISTS v_orphan_seatgeek_data CASCADE;
CREATE VIEW v_orphan_seatgeek_data AS
SELECT 'listings'::text AS kind, sg_event_id, COUNT(*) AS row_count, MAX(captured_at) AS last_seen
  FROM seatgeek_listings_snapshots WHERE tevo_event_id IS NULL GROUP BY sg_event_id
UNION ALL
SELECT 'sales', sg_event_id, COUNT(*), MAX(pulled_at)
  FROM seatgeek_sales_snapshots WHERE tevo_event_id IS NULL GROUP BY sg_event_id
UNION ALL
SELECT 'orders', sg_event_id, COUNT(*), MAX(pulled_at)
  FROM seatgeek_orders WHERE tevo_event_id IS NULL AND sg_event_id IS NOT NULL GROUP BY sg_event_id
UNION ALL
SELECT 'seller_listings', sg_event_id, COUNT(*), MAX(pulled_at)
  FROM seatgeek_seller_listings WHERE tevo_event_id IS NULL GROUP BY sg_event_id;

DROP VIEW IF EXISTS v_orphan_seatdata_data CASCADE;
CREATE VIEW v_orphan_seatdata_data AS
SELECT 'event_stats'::text AS kind, sd_event_id, COUNT(*) AS row_count, MAX(pulled_at) AS last_seen
  FROM seatdata_event_stats WHERE tevo_event_id IS NULL GROUP BY sd_event_id
UNION ALL
SELECT 'listings', sd_event_id, COUNT(*), MAX(pulled_at)
  FROM seatdata_listings_snapshots WHERE tevo_event_id IS NULL GROUP BY sd_event_id
UNION ALL
SELECT 'sales', sd_event_id, COUNT(*), MAX(pulled_at)
  FROM seatdata_sales_snapshots WHERE tevo_event_id IS NULL GROUP BY sd_event_id;

-- v_event_overlay_summary: per-event coverage of every overlay domain.
-- Use this to find events lacking any context signal.
DROP VIEW IF EXISTS v_event_overlay_summary CASCADE;
CREATE VIEW v_event_overlay_summary AS
SELECT
  b.tevo_event_id,
  b.event_date,
  b.tevo_venue_id,
  b.tevo_performer_id,
  EXISTS (SELECT 1 FROM v_event_holidays           h WHERE h.tevo_event_id = b.tevo_event_id) AS has_holiday,
  EXISTS (SELECT 1 FROM v_event_school_breaks      s WHERE s.tevo_event_id = b.tevo_event_id) AS has_school_break,
  EXISTS (SELECT 1 FROM v_event_weather            w WHERE w.tevo_event_id = b.tevo_event_id) AS has_weather,
  EXISTS (SELECT 1 FROM v_event_nws_alerts         a WHERE a.tevo_event_id = b.tevo_event_id) AS has_nws_alert,
  EXISTS (SELECT 1 FROM v_event_reddit             r WHERE r.tevo_event_id = b.tevo_event_id) AS has_reddit,
  EXISTS (SELECT 1 FROM v_event_major_calendar     m WHERE m.tevo_event_id = b.tevo_event_id) AS has_major_calendar,
  EXISTS (SELECT 1 FROM v_event_sporting_rivalries v WHERE v.tevo_event_id = b.tevo_event_id) AS has_rivalry,
  EXISTS (SELECT 1 FROM v_event_mlb_branded_series mb WHERE mb.tevo_event_id = b.tevo_event_id) AS has_branded_series,
  EXISTS (SELECT 1 FROM v_event_espn_news          n WHERE n.tevo_event_id = b.tevo_event_id) AS has_espn_news,
  EXISTS (SELECT 1 FROM v_event_espn_injuries      i WHERE i.tevo_event_id = b.tevo_event_id) AS has_espn_injuries,
  -- coverage score (0–10)
  (
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_holidays           h WHERE h.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_school_breaks      s WHERE s.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_weather            w WHERE w.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_nws_alerts         a WHERE a.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_reddit             r WHERE r.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_major_calendar     m WHERE m.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_sporting_rivalries v WHERE v.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_mlb_branded_series mb WHERE mb.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_espn_news          n WHERE n.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_espn_injuries      i WHERE i.tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END)
  ) AS overlay_signal_count
FROM v_event_base b;

-- The audit RPC: a single jsonb call that surfaces drift, coverage, and
-- orphan counts. Wire to a cron for daily logging or hit on-demand.
CREATE OR REPLACE FUNCTION audit_cross_source_health()
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'as_of', NOW(),
    'coverage', (SELECT jsonb_agg(to_jsonb(c.*)) FROM v_canonical_coverage_v2 c),
    'drift', jsonb_build_object(
      'rows_in_xref_missing_from_canonical',
        (SELECT COUNT(*) FROM v_canonical_drift WHERE issue='missing_from_canonical'),
      'sg_canonical_matched_but_no_xref',
        (SELECT COUNT(*) FROM v_canonical_drift WHERE issue='matched_but_no_xref')
    ),
    'orphans', jsonb_build_object(
      'seatgeek', COALESCE((SELECT jsonb_object_agg(kind, total)
                              FROM (SELECT kind, SUM(row_count) AS total
                                      FROM v_orphan_seatgeek_data
                                     GROUP BY kind) x), '{}'::jsonb),
      'seatdata', COALESCE((SELECT jsonb_object_agg(kind, total)
                              FROM (SELECT kind, SUM(row_count) AS total
                                      FROM v_orphan_seatdata_data
                                     GROUP BY kind) x), '{}'::jsonb),
      'sg_canonical_unmatched',
        (SELECT COUNT(*) FROM sg_events_canonical WHERE tevo_event_id IS NULL)
    ),
    'overlay_coverage', (
      SELECT jsonb_build_object(
        'total_events',            COUNT(*),
        'with_any_overlay',        COUNT(*) FILTER (WHERE overlay_signal_count > 0),
        'avg_signals_per_event',   ROUND(AVG(overlay_signal_count)::numeric, 2),
        'with_holiday',            COUNT(*) FILTER (WHERE has_holiday),
        'with_school_break',       COUNT(*) FILTER (WHERE has_school_break),
        'with_weather',            COUNT(*) FILTER (WHERE has_weather),
        'with_nws_alert',          COUNT(*) FILTER (WHERE has_nws_alert),
        'with_reddit',             COUNT(*) FILTER (WHERE has_reddit),
        'with_major_calendar',     COUNT(*) FILTER (WHERE has_major_calendar),
        'with_rivalry',            COUNT(*) FILTER (WHERE has_rivalry),
        'with_branded_series',     COUNT(*) FILTER (WHERE has_branded_series),
        'with_espn_news',          COUNT(*) FILTER (WHERE has_espn_news),
        'with_espn_injuries',      COUNT(*) FILTER (WHERE has_espn_injuries))
      FROM v_event_overlay_summary)
  );
$$;

GRANT EXECUTE ON FUNCTION audit_cross_source_health() TO authenticated, anon, service_role;
GRANT SELECT ON v_canonical_coverage_v2, v_canonical_drift,
                v_orphan_seatgeek_data, v_orphan_seatdata_data,
                v_event_overlay_summary
  TO authenticated, anon, service_role;
