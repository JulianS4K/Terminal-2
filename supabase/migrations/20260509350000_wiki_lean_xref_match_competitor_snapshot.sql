-- ============================================================================
-- Migration 20260509350000 — Wiki lean storage + cross-source auto-match cron
--                            + competitor analysis snapshot table
--
-- Three product directives:
--
-- (1) WIKI LEAN STORAGE — "dont store every pull only store latest, we dont
--     need to store every edit made, just the final results."
--     - Drop deprecated wiki_summary table (126 rows, schema from prior
--       generation, never read by anything).
--     - Drop the raw_summary_jsonb column from performer_wikipedia. We
--       already extract title/extract/image_url/url to first-class columns
--       and never query the raw blob.
--     - Modify process_performer_wiki_summaries() to stop populating
--       raw_summary_jsonb (the column is going away).
--     - Add wiki_pending_sweep() function + daily cron — keeps
--       performer_wiki_pending lean by deleting resolved rows >24h old.
--       Currently 339/339 rows are resolved and accumulating.
--
-- (2) CROSS-SOURCE AUTO-MATCH CRON — "write crons to auto connect
--     evo/sg/sd events ... so it doesnt get stale"
--     - SG side already has auto_match_sg_canonical() running at
--       sg_canonical_auto_match_30min — keep as-is (verified working).
--     - Add evo_orphan_event_resolve() — finds evo_order_items.event_id
--       not in events table, logs to event_match_attempts so the orphan
--       is auditable. Real backfill (TEvo /v9/events lookup) happens via
--       existing backfill-event-configurations-5min cron, but logging
--       gives us a paper trail.
--     - SD: no separate matcher needed — seatdata_event_xref is pure
--       id-based (no name/date/venue columns). Matching happens at SD
--       pull time via existing seatdata_pull infrastructure when it
--       receives an sd_event_id paired with a tevo_event_id. No-op
--       matcher function included as a placeholder for shape parity.
--     - Add unified cross_source_match_tick() that runs SG canonical
--       match + EVO orphan log + SD audit (which will mostly be empty
--       until the SD pull pipeline is fixed).
--     - Cron cross_source_match_tick_30min replaces the standalone
--       SG cron (which is folded into the unified tick).
--
-- (3) COMPETITOR ANALYSIS SNAPSHOT — "to get competitor analysis as we
--     get more events added so it doesnt get stale"
--     - v_competing_events is already a view (always fresh) but every
--       call hits the haversine math live. As event count grows, lookups
--       get slower.
--     - event_competitors_snapshot table — pre-computes the ±24h × 20mi
--       neighbor list per upcoming event, so day-trader lookups are
--       O(1) per event.
--     - refresh_event_competitors() — full rebuild from the view.
--     - Cron event_competitors_refresh_hourly — refresh every hour. As
--       new events land, they appear in the snapshot within 60min.
-- ============================================================================

-- ============================================================================
-- (1) WIKI LEAN STORAGE
-- ============================================================================

-- (1a) Drop deprecated wiki_summary table (replaced by performer_wikipedia
--     long ago; not referenced by any view or function).
DROP TABLE IF EXISTS wiki_summary;

-- (1b) Drop raw_summary_jsonb column. We already pulled out everything we
--      need into first-class columns. The blob just bloats storage.
ALTER TABLE performer_wikipedia DROP COLUMN IF EXISTS raw_summary_jsonb;

-- (1c) Replace summaries processor — drops the raw_summary_jsonb assignment.
CREATE OR REPLACE FUNCTION process_performer_wiki_summaries()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  v_body jsonb;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT pwp.tevo_performer_id, pwp.summary_request_id, h.content, h.status_code
    FROM performer_wiki_pending pwp
    JOIN net._http_response h ON h.id = pwp.summary_request_id
    WHERE pwp.stage = 'summary' AND pwp.resolved_at IS NULL
  LOOP
    v_count := v_count + 1;
    BEGIN
      v_body := r.content::jsonb;
    EXCEPTION WHEN OTHERS THEN
      v_body := NULL;
    END;

    IF r.status_code = 200 AND v_body IS NOT NULL THEN
      UPDATE performer_wikipedia SET
        wiki_pageid       = COALESCE((v_body->>'pageid')::bigint, wiki_pageid),
        wiki_title        = COALESCE(v_body->>'title', wiki_title),
        wiki_url          = COALESCE(v_body->'content_urls'->'desktop'->>'page',
                                     'https://en.wikipedia.org/wiki/' ||
                                     replace(COALESCE(v_body->>'title', wiki_title), ' ', '_')),
        description       = v_body->>'description',
        extract           = v_body->>'extract',
        image_url         = v_body->'thumbnail'->>'source',
        match_method      = 'search_top_summary',
        match_confidence  = 0.85,
        last_refreshed_at = now(),
        is_rejected       = false,
        updated_at        = now()
      WHERE tevo_performer_id = r.tevo_performer_id;
    ELSIF r.status_code = 404 THEN
      UPDATE performer_wikipedia SET
        is_rejected = true,
        reject_reason = 'summary 404 — title unresolvable',
        match_method = 'rejected',
        last_refreshed_at = now(),
        updated_at = now()
      WHERE tevo_performer_id = r.tevo_performer_id;
    END IF;

    UPDATE performer_wiki_pending SET resolved_at = now()
      WHERE tevo_performer_id = r.tevo_performer_id AND stage = 'summary';
  END LOOP;
  RETURN v_count;
END;
$$;

-- (1d) Sweep resolved wiki pending rows. Resolved rows older than 24h are
--      pure history — no consumer reads them.
CREATE OR REPLACE FUNCTION wiki_pending_sweep()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE v_deleted int;
BEGIN
  DELETE FROM performer_wiki_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '24 hours';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

COMMENT ON FUNCTION wiki_pending_sweep IS
  'Delete resolved performer_wiki_pending rows older than 24h. Consumer-less '
  'history; the actual results live in performer_wikipedia.';

-- ============================================================================
-- (2) CROSS-SOURCE AUTO-MATCH
-- ============================================================================

-- (2a) Log EVO order_items whose event_id has no row in events. The
--      backfill-event-configurations-5min cron handles the actual fetch;
--      this gives us auditability (which orphan event_ids we've seen and
--      when they first appeared in orders).
CREATE OR REPLACE FUNCTION evo_orphan_event_resolve()
RETURNS TABLE(orphans_seen int, attempts_logged int)
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  v_seen int := 0;
  v_logged int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT it.event_id, max(it.event_name) AS event_name,
                    max(it.occurs_at)::date AS event_date,
                    max(it.venue_name) AS venue_name
    FROM evo_order_items it
    WHERE it.event_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM events e WHERE e.id = it.event_id)
    GROUP BY it.event_id
  LOOP
    v_seen := v_seen + 1;
    -- Only log if we haven't logged this orphan in the past 24h
    IF NOT EXISTS (
      SELECT 1 FROM event_match_attempts
      WHERE source_key = 'tevo_orphan_in_orders'
        AND source_event_id = r.event_id::text
        AND attempted_at > now() - interval '24 hours'
    ) THEN
      INSERT INTO event_match_attempts (
        source_key, source_event_id, attempted_at,
        match_method, reason_unmatched, notes
      ) VALUES (
        'tevo_orphan_in_orders', r.event_id::text, now(),
        'awaiting_backfill', 'event not in events table',
        jsonb_build_object(
          'event_name', r.event_name,
          'event_date', r.event_date,
          'venue_name', r.venue_name)
      );
      v_logged := v_logged + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_seen, v_logged;
END;
$$;

-- (2b) SeatData xref audit. seatdata_event_xref is pure id-based — no
--      name/date/venue columns to match on, so the actual pairing must
--      happen upstream (at SD pull time). This function just COUNTS
--      orphans for visibility / alerting.
CREATE OR REPLACE FUNCTION sd_xref_resolve()
RETURNS TABLE(orphan_xref_rows int, sd_pulls_logged int)
LANGUAGE plpgsql
AS $$
DECLARE
  v_orphans int;
  v_pulls   int;
BEGIN
  SELECT count(*) INTO v_orphans FROM seatdata_event_xref WHERE tevo_event_id IS NULL;
  SELECT count(*) INTO v_pulls FROM seatdata_pull_log;
  RETURN QUERY SELECT v_orphans, v_pulls;
END;
$$;

COMMENT ON FUNCTION sd_xref_resolve IS
  'SD audit only — xref table is id-based, no fields to match on. Returns '
  'count of orphan xref rows + pull log size so the unified tick can '
  'surface "SD pipeline silent" without a per-row matcher.';

-- (2c) Unified cross-source match tick. Runs every 30 min.
CREATE OR REPLACE FUNCTION cross_source_match_tick()
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_sg jsonb; v_evo record; v_sd record;
BEGIN
  v_sg  := sg_canonical_auto_match_tick();
  SELECT * INTO v_evo FROM evo_orphan_event_resolve();
  SELECT * INTO v_sd  FROM sd_xref_resolve();

  RETURN jsonb_build_object(
    'sg', v_sg,
    'evo', jsonb_build_object(
      'orphans_seen', v_evo.orphans_seen,
      'attempts_logged', v_evo.attempts_logged
    ),
    'sd', jsonb_build_object(
      'orphan_xref_rows', v_sd.orphan_xref_rows,
      'sd_pulls_logged', v_sd.sd_pulls_logged
    ),
    'ran_at', now()
  );
END;
$$;

COMMENT ON FUNCTION cross_source_match_tick IS
  'Unified cross-source matcher. Runs SG canonical match + EVO orphan log + '
  'SD xref resolve. Cron: cross_source_match_tick_30min.';

-- ============================================================================
-- (3) COMPETITOR ANALYSIS SNAPSHOT
-- ============================================================================

CREATE TABLE IF NOT EXISTS event_competitors_snapshot (
  tevo_event_id     bigint PRIMARY KEY,
  competitors_count int,
  competitors       jsonb,    -- array of {tevo_event_id, name, venue_name, distance_mi, hours_offset}
  refreshed_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS event_competitors_snapshot_refresh_idx
  ON event_competitors_snapshot(refreshed_at DESC);

COMMENT ON TABLE event_competitors_snapshot IS
  'Pre-computed competing-events list per upcoming TEvo event (±24h × 20mi). '
  'Refreshed hourly by event_competitors_refresh_hourly cron. Use this for '
  'fast lookups; v_competing_events for fresh ad-hoc analysis.';

CREATE OR REPLACE FUNCTION refresh_event_competitors()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE v_rows int;
BEGIN
  -- Full rebuild — small enough table that incremental isn't worth the
  -- complexity. ~300 upcoming events × small jsonb = trivial.
  TRUNCATE event_competitors_snapshot;

  INSERT INTO event_competitors_snapshot(tevo_event_id, competitors_count, competitors, refreshed_at)
  SELECT
    tevo_event_id,
    count(*)::int,
    jsonb_agg(
      jsonb_build_object(
        'tevo_event_id', competing_event_id,
        'name', competing_event_name,
        'venue_name', competing_venue_name,
        'distance_mi', round(distance_miles::numeric, 1),
        'hours_offset', round(hours_offset::numeric, 1)
      ) ORDER BY distance_miles, abs(hours_offset)
    ),
    now()
  FROM v_competing_events
  GROUP BY tevo_event_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION refresh_event_competitors IS
  'Rebuild event_competitors_snapshot from v_competing_events. Hourly cron.';

-- ============================================================================
-- (4) WIRE THE CRONS
-- ============================================================================

-- Replace the old SG-only matcher with the unified one
DO $$
BEGIN
  PERFORM cron.unschedule('sg_canonical_auto_match_30min');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT cron.schedule(
  'cross_source_match_tick_30min',
  '*/30 * * * *',
  $$ SELECT cross_source_match_tick(); $$
);

-- Wiki pending sweep — daily at 03:30 UTC (off-peak)
SELECT cron.schedule(
  'wiki_pending_sweep_daily',
  '30 3 * * *',
  $$ SELECT wiki_pending_sweep(); $$
);

-- Competitor snapshot refresh — hourly at :40
SELECT cron.schedule(
  'event_competitors_refresh_hourly',
  '40 * * * *',
  $$ SELECT refresh_event_competitors(); $$
);
