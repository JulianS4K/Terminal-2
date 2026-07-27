-- ============================================================================
-- Migration 20260509330000 — Unmatched events bucket + Wikipedia pageviews
--
-- (a) v_unmatched_events — UNION orphan events across SG + SD + EVO.
--     Single bucket for "events I should manually map" workflow.
-- (b) event_match_attempts — log table so iterative matching is auditable.
-- (c) performer_wiki_pageviews + cron — finally USING Wikipedia data
--     beyond storage. Daily article views = real buzz signal.
-- ============================================================================

CREATE OR REPLACE VIEW v_unmatched_events AS
SELECT
  'sg_broker'::text AS source_key,
  sgc.sg_event_id::text       AS source_event_id,
  sgc.sg_event_name           AS source_event_name,
  sgc.sg_event_date           AS source_event_date,
  sgc.sg_venue_name           AS source_venue,
  sgc.sg_category             AS source_category,
  jsonb_build_object(
    'has_seller_listings', sgc.has_seller_listings,
    'has_orders',          sgc.has_orders,
    'has_v2_pulled',       sgc.has_v2_listings_pulled
  ) AS source_signals,
  'no_tevo_match'             AS unmatch_reason,
  sgc.updated_at              AS last_seen
FROM sg_events_canonical sgc
WHERE sgc.tevo_event_id IS NULL
UNION ALL
SELECT
  'seatdata'::text,
  sdx.sd_event_id::text,
  NULL::text, NULL::date, NULL::text, NULL::text,
  jsonb_build_object('match_attempted_at', sdx.matched_at),
  'no_tevo_match',
  sdx.matched_at
FROM seatdata_event_xref sdx
WHERE sdx.tevo_event_id IS NULL
UNION ALL
SELECT
  'tevo_orphan_in_orders'::text,
  o.event_id::text,
  o.event_name, o.occurs_at::date, o.venue_name, NULL::text,
  jsonb_build_object('order_count', o.order_count, 'venue_id', o.venue_id),
  'tevo_event_not_in_events_table',
  o.latest_pulled
FROM (
  SELECT
    it.event_id, max(it.event_name) AS event_name,
    max(it.occurs_at) AS occurs_at, max(it.venue_name) AS venue_name,
    max(it.venue_id) AS venue_id, count(*) AS order_count,
    max(eo.pulled_at) AS latest_pulled
  FROM evo_order_items it
  LEFT JOIN evo_orders eo ON eo.evo_order_id = it.evo_order_id
  WHERE it.event_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM events e WHERE e.id = it.event_id)
  GROUP BY it.event_id
) o;

COMMENT ON VIEW v_unmatched_events IS
  'Single bucket of orphan events across all sources. SG without TEvo xref, '
  'SD without TEvo xref, and TEvo event_ids referenced by orders but missing '
  'from events table. Drives the "find me events to manually map" workflow.';

CREATE TABLE IF NOT EXISTS event_match_attempts (
  id                       bigserial PRIMARY KEY,
  source_key               text NOT NULL,
  source_event_id          text NOT NULL,
  attempted_at             timestamptz DEFAULT now(),
  matched_tevo_event_id    bigint,
  match_method             text,
  match_confidence         numeric(3,2),
  reason_unmatched         text,
  candidate_pool_size      int,
  notes                    jsonb
);

CREATE INDEX IF NOT EXISTS event_match_attempts_source_idx
  ON event_match_attempts(source_key, source_event_id, attempted_at DESC);

COMMENT ON TABLE event_match_attempts IS
  'Audit log of every event-matching attempt. Lets the day-trader trace '
  'why an event landed in v_unmatched_events and what was tried.';

-- Wikipedia pageviews
CREATE TABLE IF NOT EXISTS performer_wiki_pageviews (
  tevo_performer_id  bigint NOT NULL,
  date               date NOT NULL,
  views              int,
  pulled_at          timestamptz DEFAULT now(),
  PRIMARY KEY (tevo_performer_id, date)
);

CREATE INDEX IF NOT EXISTS performer_wiki_pageviews_recent_idx
  ON performer_wiki_pageviews(date DESC, tevo_performer_id);

CREATE TABLE IF NOT EXISTS performer_wiki_pageviews_pending (
  tevo_performer_id  bigint PRIMARY KEY,
  request_id         bigint,
  fired_at           timestamptz DEFAULT now(),
  resolved_at        timestamptz
);

CREATE OR REPLACE FUNCTION wiki_pageviews_queue(p_limit int DEFAULT 30)
RETURNS int AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0;
  v_start date := current_date - interval '30 days';
  v_end   date := current_date - interval '1 day';
  v_url   text;
BEGIN
  FOR r IN
    SELECT pw.tevo_performer_id, pw.wiki_title
    FROM performer_wikipedia pw
    LEFT JOIN performer_wiki_pageviews_pending p ON p.tevo_performer_id = pw.tevo_performer_id
        AND p.fired_at > now() - interval '20 hours'
    WHERE pw.wiki_pageid IS NOT NULL AND NOT pw.is_rejected AND p.tevo_performer_id IS NULL
    ORDER BY pw.tevo_performer_id LIMIT p_limit
  LOOP
    v_url := 'https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/en.wikipedia/all-access/all-agents/' ||
             replace(r.wiki_title, ' ', '_') || '/daily/' ||
             to_char(v_start, 'YYYYMMDD') || '/' || to_char(v_end, 'YYYYMMDD');
    SELECT net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'User-Agent', 'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
        'Accept', 'application/json'),
      timeout_milliseconds := 12000
    ) INTO v_req_id;
    INSERT INTO performer_wiki_pageviews_pending(tevo_performer_id, request_id, fired_at)
    VALUES (r.tevo_performer_id, v_req_id, now())
    ON CONFLICT (tevo_performer_id) DO UPDATE SET
      request_id = EXCLUDED.request_id, fired_at = now(), resolved_at = NULL;
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION wiki_pageviews_process()
RETURNS TABLE(processed int, rows_persisted int) AS $$
DECLARE
  r RECORD; v_body jsonb; v_items jsonb;
  v_processed int := 0; v_persisted int := 0; v_count int;
BEGIN
  FOR r IN
    SELECT p.tevo_performer_id, h.content, h.status_code
    FROM performer_wiki_pageviews_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      v_items := COALESCE(v_body->'items', '[]'::jsonb);
      WITH src AS (SELECT i FROM jsonb_array_elements(v_items) AS i),
      ins AS (
        INSERT INTO performer_wiki_pageviews(tevo_performer_id, date, views, pulled_at)
        SELECT r.tevo_performer_id, to_date(src.i->>'timestamp', 'YYYYMMDDHH24'),
               (src.i->>'views')::int, now()
        FROM src
        ON CONFLICT (tevo_performer_id, date) DO UPDATE SET
          views = EXCLUDED.views, pulled_at = now()
        RETURNING 1
      )
      SELECT count(*) INTO v_count FROM ins;
      v_persisted := v_persisted + v_count;
    END IF;
    UPDATE performer_wiki_pageviews_pending SET resolved_at = now()
      WHERE tevo_performer_id = r.tevo_performer_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW v_performer_pageview_trend AS
WITH agg AS (
  SELECT
    tevo_performer_id,
    sum(views) FILTER (WHERE date >= current_date - 7)  AS views_7d,
    sum(views) FILTER (WHERE date >= current_date - 14) AS views_14d,
    sum(views) FILTER (WHERE date >= current_date - 30) AS views_30d,
    max(views) AS peak_views,
    max(date)  AS latest_date
  FROM performer_wiki_pageviews
  WHERE date >= current_date - 30
  GROUP BY tevo_performer_id
)
SELECT
  pw.tevo_performer_id, pw.performer_name, pw.wiki_title, pw.wiki_url,
  agg.views_7d, agg.views_14d, agg.views_30d,
  CASE WHEN (agg.views_30d - agg.views_14d) > 0
    THEN round(((agg.views_30d - agg.views_14d) / 16.0)::numeric, 0)
    ELSE NULL END AS baseline_daily_views,
  CASE WHEN agg.views_7d > 0
    THEN round((agg.views_7d / 7.0)::numeric, 0) ELSE NULL END AS recent_daily_views,
  CASE WHEN (agg.views_30d - agg.views_14d) > 100
    THEN round(((agg.views_7d / 7.0) / ((agg.views_30d - agg.views_14d) / 16.0))::numeric, 2)
    ELSE NULL END AS spike_multiplier,
  agg.peak_views, agg.latest_date
FROM performer_wikipedia pw
JOIN agg USING (tevo_performer_id);

COMMENT ON VIEW v_performer_pageview_trend IS
  'Per-performer Wikipedia pageviews trend. spike_multiplier = recent_7d_avg '
  '/ baseline_14_30d_avg. >1.5 = trending up. Real buzz signal independent '
  'of price action.';

SELECT cron.schedule('wiki_pageviews_queue_daily',  '30 6 * * *', $$ SELECT wiki_pageviews_queue(60); $$);
SELECT cron.schedule('wiki_pageviews_process_daily','35 6 * * *', $$ SELECT wiki_pageviews_process(); $$);
