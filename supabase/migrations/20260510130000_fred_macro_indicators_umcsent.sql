-- ============================================================================
-- Migration 20260510130000 — FRED macro indicators (UMCSENT seed)
--
-- Adds a generic macro-economic indicator pipeline pulling from FRED
-- (St. Louis Fed). Seeds with UMCSENT (U Michigan Consumer Sentiment) —
-- chosen as the first integration because it just printed an all-time
-- low (48.2 in early-May 2026) which makes it a high-signal moment, and
-- because consumer sentiment historically leads discretionary spending
-- by 1-2 months — directly relevant to event-ticket demand.
--
-- Design intent:
--   * Generic schema: macro_indicators is keyed by (series_id, ...) so any
--     future FRED series (MRTSSM722USS food/drink, RSAFS retail, etc.)
--     plugs in via one INSERT into a config table and one cron entry.
--   * Backfill 12 months on first run, then incremental daily — the API
--     is free + cheap, so idempotent re-pulls are simpler than tracking
--     state.
--   * Revision history preserved (realtime_start) so future backtests
--     aren't contaminated by lookahead bias. UMCSENT publishes a
--     preliminary mid-month then a final end-of-month — both stored.
--
-- Pre-req before this matters: a FRED API key must be in vault as
--   FRED_API_KEY. Free signup: https://fred.stlouisfed.org/docs/api/api_key.html
-- Set with:
--   SELECT vault.create_secret('YOUR_KEY_HERE', 'FRED_API_KEY');
-- Without it, fred_pending rows accumulate with status='no_api_key'.
--
-- Mirrors the queue/process pg_net pattern from the espn_scoreboard
-- migration (20260510120000) to stay consistent with codebase conventions.
-- ============================================================================

-- ============================================================================
-- (1) Storage — observations with revision history
-- ============================================================================
CREATE TABLE IF NOT EXISTS macro_indicators (
  series_id        text  NOT NULL,
  observation_date date  NOT NULL,
  value            numeric,                    -- nullable: FRED uses '.' for missing
  realtime_start   date  NOT NULL,             -- when this revision was first published
  realtime_end     date,                       -- 9999-12-31 = currently valid
  ingested_at      timestamptz DEFAULT now(),
  PRIMARY KEY (series_id, observation_date, realtime_start)
);

CREATE INDEX IF NOT EXISTS macro_indicators_series_date_idx
  ON macro_indicators (series_id, observation_date DESC);

COMMENT ON TABLE macro_indicators IS
  'FRED-sourced macro-economic indicators with revision history. '
  'Use v_macro_indicators_latest for current values; query directly '
  'for as-of-date / preliminary-vs-final analysis.';

-- Latest revision per (series, observation_date) — what you join to events / orders
CREATE OR REPLACE VIEW v_macro_indicators_latest AS
SELECT DISTINCT ON (series_id, observation_date)
  series_id, observation_date, value, realtime_start, realtime_end, ingested_at
FROM macro_indicators
ORDER BY series_id, observation_date, realtime_start DESC;

COMMENT ON VIEW v_macro_indicators_latest IS
  'Latest revision (final > preliminary) per (series_id, observation_date).';

-- ============================================================================
-- (2) Series catalog — declarative list of what to pull
-- ============================================================================
CREATE TABLE IF NOT EXISTS macro_series_config (
  series_id     text PRIMARY KEY,
  display_name  text NOT NULL,
  units         text,
  frequency     text NOT NULL,                 -- 'M' (monthly), 'Q' (quarterly), 'D' (daily)
  source        text NOT NULL DEFAULT 'FRED',
  enabled       boolean NOT NULL DEFAULT true,
  notes         text,
  added_at      timestamptz DEFAULT now()
);

INSERT INTO macro_series_config (series_id, display_name, units, frequency, notes) VALUES
  ('UMCSENT', 'U Michigan Consumer Sentiment', 'Index 1966=100', 'M',
   'Preliminary mid-month, final end-month. Leads discretionary spend by 1-2 months.')
ON CONFLICT (series_id) DO NOTHING;

-- ============================================================================
-- (3) Pending queue (mirrors espn_scoreboard_pending)
-- ============================================================================
CREATE TABLE IF NOT EXISTS fred_pending (
  id              bigserial PRIMARY KEY,
  series_id       text NOT NULL,
  request_id      bigint NOT NULL,
  observation_start date,
  fired_at        timestamptz DEFAULT now(),
  resolved_at     timestamptz,
  http_status     int,
  rows_upserted   int,
  error           text
);
CREATE INDEX IF NOT EXISTS fred_pending_unresolved_idx
  ON fred_pending(series_id) WHERE resolved_at IS NULL;

-- ============================================================================
-- (4) Queue: fire one HTTP request per enabled series
-- ============================================================================
CREATE OR REPLACE FUNCTION fred_queue_all(p_months_back int DEFAULT 12)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_api_key text;
  v_start   date := (current_date - (p_months_back || ' months')::interval)::date;
  cfg       RECORD;
  v_req     bigint;
  v_count   int := 0;
BEGIN
  SELECT decrypted_secret INTO v_api_key
  FROM vault.decrypted_secrets WHERE name = 'FRED_API_KEY' LIMIT 1;

  IF v_api_key IS NULL OR v_api_key = '' THEN
    -- Log a sentinel row so the operator can see the cron is blocked on key setup
    INSERT INTO fred_pending(series_id, request_id, observation_start,
                             resolved_at, http_status, error)
    VALUES ('__config__', 0, v_start, now(), 0, 'FRED_API_KEY missing in vault.decrypted_secrets');
    RETURN 0;
  END IF;

  FOR cfg IN SELECT series_id FROM macro_series_config WHERE enabled = true
  LOOP
    SELECT net.http_get(
      url := 'https://api.stlouisfed.org/fred/series/observations',
      params := jsonb_build_object(
        'series_id',         cfg.series_id,
        'api_key',           v_api_key,
        'file_type',         'json',
        'observation_start', v_start::text
      ),
      headers := jsonb_build_object(
        'Accept',     'application/json',
        'User-Agent', 'terminal-2-broker (julian@s4kent.com)'
      ),
      timeout_milliseconds := 15000
    ) INTO v_req;

    INSERT INTO fred_pending(series_id, request_id, observation_start)
    VALUES (cfg.series_id, v_req, v_start);

    v_count := v_count + 1;
    PERFORM pg_sleep(0.3);  -- be polite even though FRED is generous (120 req/min)
  END LOOP;

  RETURN v_count;
END $$;

COMMENT ON FUNCTION fred_queue_all(integer) IS
  'Fires one FRED API request per enabled macro_series_config row. '
  'Default 12mo backfill window; idempotent — re-pulls overwrite latest revision.';

-- ============================================================================
-- (5) Process: drain pending → macro_indicators
-- ============================================================================
CREATE OR REPLACE FUNCTION fred_process_pending()
RETURNS TABLE(processed int, rows_upserted int) LANGUAGE plpgsql AS $$
DECLARE
  r          RECORD;
  v_body     jsonb;
  v_obs      jsonb;
  v_inserted int;
  v_total_inserted int := 0;
  v_processed int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.series_id, h.content, h.status_code
    FROM fred_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
      AND p.series_id <> '__config__'
  LOOP
    v_processed := v_processed + 1;
    v_inserted := 0;

    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;

      IF v_body IS NOT NULL AND v_body ? 'observations' THEN
        FOR v_obs IN SELECT jsonb_array_elements(v_body -> 'observations')
        LOOP
          INSERT INTO macro_indicators (
            series_id, observation_date, value, realtime_start, realtime_end
          ) VALUES (
            r.series_id,
            (v_obs ->> 'date')::date,
            CASE WHEN v_obs ->> 'value' = '.' THEN NULL
                 ELSE (v_obs ->> 'value')::numeric END,
            (v_obs ->> 'realtime_start')::date,
            (v_obs ->> 'realtime_end')::date
          )
          ON CONFLICT (series_id, observation_date, realtime_start) DO UPDATE
            SET value = EXCLUDED.value,
                realtime_end = EXCLUDED.realtime_end,
                ingested_at = now();
          v_inserted := v_inserted + 1;
        END LOOP;
      END IF;
    END IF;

    UPDATE fred_pending
       SET resolved_at = now(),
           http_status = r.status_code,
           rows_upserted = v_inserted,
           error = CASE WHEN r.status_code <> 200
                        THEN substr(r.content::text, 1, 500)
                        ELSE NULL END
     WHERE id = r.pending_id;

    v_total_inserted := v_total_inserted + v_inserted;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_total_inserted;
END $$;

COMMENT ON FUNCTION fred_process_pending() IS
  'Drains fred_pending into macro_indicators with revision history preserved.';

-- ============================================================================
-- (6) Health view — operator visibility
-- ============================================================================
CREATE OR REPLACE VIEW v_macro_indicators_health AS
SELECT
  c.series_id,
  c.display_name,
  c.frequency,
  c.enabled,
  l.observation_date AS latest_obs_date,
  l.value            AS latest_value,
  l.realtime_start   AS latest_revision_at,
  l.ingested_at      AS latest_ingested_at,
  (SELECT count(*) FROM macro_indicators m WHERE m.series_id = c.series_id) AS total_rows,
  (SELECT max(fired_at) FROM fred_pending fp WHERE fp.series_id = c.series_id) AS last_pull_at,
  (SELECT max(fp.error) FROM fred_pending fp
    WHERE fp.series_id = c.series_id AND fp.resolved_at >= now() - interval '24 hours'
      AND fp.error IS NOT NULL) AS recent_error
FROM macro_series_config c
LEFT JOIN v_macro_indicators_latest l ON l.series_id = c.series_id;

COMMENT ON VIEW v_macro_indicators_health IS
  'Per-series freshness + last-pull + recent-error for the macro pipeline.';

-- ============================================================================
-- (7) Grants
-- ============================================================================
GRANT SELECT ON macro_indicators                TO anon;
GRANT SELECT ON v_macro_indicators_latest       TO anon;
GRANT SELECT ON macro_series_config             TO anon;
GRANT SELECT ON v_macro_indicators_health       TO anon;

-- ============================================================================
-- (8) Cron schedules
--
-- UMCSENT release cadence:
--   * Preliminary: ~2nd Friday of month, ~10am ET
--   * Final:       last Friday of month, ~10am ET
-- We don't predict release dates — daily idempotent re-pull is simpler
-- and FRED API is free with a 120 req/min limit (we use 1 req/series/day).
--
-- Queue: 11:30am ET = 15:30 UTC (well after the 10am ET data refresh)
-- Process: every 5 min on the 5-59 offset to catch async pg_net responses
-- ============================================================================
SELECT cron.schedule('fred_queue_daily',
  '30 15 * * *',
  $$ SELECT public.fred_queue_all(12); $$);

SELECT cron.schedule('fred_process_5min',
  '5-59/5 * * * *',
  $$ SELECT public.fred_process_pending(); $$);

-- ============================================================================
-- (9) Trigger initial backfill
--
-- Fires once on migration apply. Will fail silently (logged in fred_pending)
-- if FRED_API_KEY isn't in vault yet — operator can manually re-trigger
-- via `SELECT public.fred_queue_all(12);` after setting the key.
-- ============================================================================
SELECT public.fred_queue_all(12);
