-- ============================================================================
-- Migration 20260702235500 — TSA daily airport passenger throughput (macro)
--
-- Lane:     A1 data plane (macro pipeline — same owner as the FRED macro_* set)
-- Touches:  macro_series_config (W: 1 seed row, source='TSA'),
--           macro_indicators (W: series_id='TSA_THROUGHPUT'),
--           tsa_pending (W: new pg_net queue-tracking table),
--           tsa_queue()/tsa_process()/tsa_sweep() (W: new fns),
--           v_macro_indicators_latest / _health (R: reused, unchanged)
-- Pre-reqs: 20260510130000 (macro_indicators + macro_series_config + latest view),
--           external: www.tsa.gov reachable from pg_net (verified live 2026-07-02)
--
-- WHY: the operator asked for a free airport/passenger-demand macro signal
--   ("free available passenger info in airports or similar"). TSA publishes a
--   DAILY national checkpoint-throughput number — the cleanest free travel-demand
--   proxy there is. National discretionary travel leads live-event demand, so it
--   belongs in the same macro overlay lane as UMCSENT (consumer sentiment).
--
-- WHY A NEW PIPELINE (not fred_queue_all): FRED does not carry TSA throughput,
--   and the FRED queue hard-codes api.stlouisfed.org. TSA has no official JSON
--   API — the numbers live in an HTML <table> at tsa.gov/travel/passenger-volumes.
--   So this is a small dedicated scraper that lands rows in the SAME generic
--   macro_indicators table (series_id-keyed, source column already anticipated a
--   non-FRED source), so get_macro_series + v_macro_indicators_latest/_health all
--   serve it with zero changes. Mirrors the reddit_news HTML-regex-over-pg_net
--   pattern (mig 20260626120030).
--
--   ✓ VERIFIED LIVE 2026-07-02 (pg_net from prod, req 1455382):
--     * GET https://www.tsa.gov/travel/passenger-volumes → 200, ~367 KB HTML.
--     * The data rows are a flat two-cell table:
--         <tr><td class="text-align-center">7/1/2026</td>
--             <td class="text-align-center">2,654,017</td></tr>
--       Regex '<tr><td[^>]*>(\d{1,2}/\d{1,2}/\d{4})</td><td[^>]*>([\d,]+)</td></tr>'
--       extracted 182 clean (date, throughput) rows, newest first (2026-07-01 =
--       2,654,017), oldest ~6 months back. M/D/YYYY dates; comma-grouped ints.
--     * The page carries the trailing ~6 months in one response, so a single
--       daily pull keeps the series complete (idempotent upsert; no backfill loop).
--   If TSA ever changes the markup, tsa_process() persists 0 rows and the
--   v_macro_indicators_health `recent_error`/freshness surfaces it (same as FRED).
--
-- KEYING: macro_indicators PK (series_id, observation_date, realtime_start). TSA
--   has no revisions, so realtime_start := observation_date (stable → re-pulls
--   upsert the same row; v_macro_indicators_latest stays one-row-per-date).
--   realtime_end := '9999-12-31' (currently valid), matching the FRED convention.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Series catalog entry — source='TSA' (the config already carries a source
--     column; UMCSENT defaults 'FRED'). frequency 'D' (daily).
-- ----------------------------------------------------------------------------
INSERT INTO macro_series_config (series_id, display_name, units, frequency, source, notes) VALUES
  ('TSA_THROUGHPUT', 'TSA Daily Airport Throughput', 'passengers/day', 'D', 'TSA',
   'National TSA checkpoint passenger volume. Scraped daily from '
   'tsa.gov/travel/passenger-volumes (no official API). Free travel-demand proxy; '
   'national discretionary travel leads live-event demand.')
ON CONFLICT (series_id) DO UPDATE
  SET display_name = EXCLUDED.display_name,
      units        = EXCLUDED.units,
      frequency    = EXCLUDED.frequency,
      source       = EXCLUDED.source,
      notes        = EXCLUDED.notes;

-- ----------------------------------------------------------------------------
-- (2) Pending queue (mirrors fred_pending / reddit_news_pending).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tsa_pending (
  id            bigserial PRIMARY KEY,
  request_id    bigint NOT NULL,
  fired_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  http_status   int,
  rows_upserted int,
  error         text
);
CREATE INDEX IF NOT EXISTS tsa_pending_unresolved_idx
  ON tsa_pending(fired_at) WHERE resolved_at IS NULL;

COMMENT ON TABLE tsa_pending IS
  'pg_net queue-tracking for the TSA throughput scraper. One row per tsa_queue() '
  'fire; tsa_process() drains it into macro_indicators (series TSA_THROUGHPUT).';

-- ----------------------------------------------------------------------------
-- (3) Queue — fire ONE GET for the TSA volumes page.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tsa_queue()
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_req bigint;
BEGIN
  SELECT net.http_get(
    url := 'https://www.tsa.gov/travel/passenger-volumes',
    headers := jsonb_build_object(
      'Accept',     'text/html',
      -- TSA serves a bot block-page to non-browser UAs; a browser-ish UA gets the
      -- real table (verified live 2026-07-02).
      'User-Agent', 'Mozilla/5.0 (compatible; Terminal2-S4K/1.0; +julian@s4kent.com)'),
    timeout_milliseconds := 20000
  ) INTO v_req;

  INSERT INTO tsa_pending(request_id) VALUES (v_req);
  RETURN v_req;
END $$;

COMMENT ON FUNCTION tsa_queue() IS
  'Fires one pg_net GET for tsa.gov/travel/passenger-volumes. Idempotent — the '
  'page carries ~6 months, so one daily pull keeps the series complete.';

-- ----------------------------------------------------------------------------
-- (4) Process — parse the HTML table → macro_indicators.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tsa_process()
RETURNS TABLE(processed int, rows_upserted int) LANGUAGE plpgsql AS $$
DECLARE
  r          RECORD;
  v_inserted int;
  v_total    int := 0;
  v_proc     int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, h.content, h.status_code
    FROM tsa_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_proc := v_proc + 1;
    v_inserted := 0;

    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      WITH matches AS (
        SELECT (regexp_matches(
                  r.content,
                  '<tr><td[^>]*>(\d{1,2}/\d{1,2}/\d{4})</td><td[^>]*>([\d,]+)</td></tr>',
                  'g'))::text[] AS m
      ),
      parsed AS (
        SELECT to_date((m)[1], 'MM/DD/YYYY')            AS obs_date,
               NULLIF(replace((m)[2], ',', ''), '')::numeric AS val
        FROM matches
      ),
      ins AS (
        INSERT INTO macro_indicators
          (series_id, observation_date, value, realtime_start, realtime_end)
        SELECT 'TSA_THROUGHPUT', p.obs_date, p.val, p.obs_date, DATE '9999-12-31'
        FROM parsed p
        WHERE p.obs_date IS NOT NULL AND p.val IS NOT NULL
        ON CONFLICT (series_id, observation_date, realtime_start) DO UPDATE
          SET value = EXCLUDED.value,
              realtime_end = EXCLUDED.realtime_end,
              ingested_at = now()
        RETURNING 1
      )
      SELECT count(*) INTO v_inserted FROM ins;
    END IF;

    UPDATE tsa_pending
       SET resolved_at   = now(),
           http_status   = r.status_code,
           rows_upserted = v_inserted,
           error = CASE WHEN r.status_code <> 200
                        THEN 'http '||coalesce(r.status_code,0)
                        WHEN v_inserted = 0
                        THEN 'parsed 0 rows (markup change?)'
                        ELSE NULL END
     WHERE id = r.pending_id;

    v_total := v_total + v_inserted;
  END LOOP;

  RETURN QUERY SELECT v_proc, v_total;
END $$;

COMMENT ON FUNCTION tsa_process() IS
  'Drains tsa_pending: regex-parses the tsa.gov volumes table into macro_indicators '
  '(series TSA_THROUGHPUT). Flags http!=200 or a 0-row parse (markup drift) in '
  'tsa_pending.error, surfaced by v_macro_indicators_health.';

-- ----------------------------------------------------------------------------
-- (5) Sweep — retain resolved pendings for 6h (freshness debugging), then prune.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tsa_sweep()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM tsa_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '6 hours';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ----------------------------------------------------------------------------
-- (6) Crons. Queue once daily (TSA posts the prior day mid-morning ET; pull at
--     16:00 UTC = ~11-12 ET). Process every 5 min on the 2-59 offset (pg_net is
--     async, response lands within seconds). Sweep daily.
-- ----------------------------------------------------------------------------
-- Minute marks avoid the saturated :00/:02/:05/:07 clusters (MIGRATION_CONVENTIONS).
SELECT cron.schedule('tsa_queue_daily',    '13 16 * * *',    $$ SELECT public.tsa_queue(); $$);
SELECT cron.schedule('tsa_process_5min',   '3-59/5 * * * *', $$ SELECT public.tsa_process(); $$);
SELECT cron.schedule('tsa_sweep_daily',    '43 16 * * *',    $$ SELECT public.tsa_sweep(); $$);

-- ----------------------------------------------------------------------------
-- (7) Trigger the initial pull on apply (fills ~6 months immediately).
-- ----------------------------------------------------------------------------
SELECT public.tsa_queue();
