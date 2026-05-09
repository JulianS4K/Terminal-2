-- ============================================================================
-- Migration 20260509170000 — Wikipedia enrichment for performers
--
-- Two-stage async pipeline using pg_net + Wikipedia REST API (no auth):
--   Stage 1: opensearch -> top article title for each performer name
--   Stage 2: REST summary -> pageid, extract, image, description
--
-- Wikipedia rate limit (per their User-Agent policy): 200/min unauthenticated.
-- We pace at 0.5s between calls (2 req/s = 120/min — well under limit).
-- The crons run every 5 min, queueing 20 performers per tick. Full enrichment
-- of the current performer base (~183) takes ~50 min from cold start.
--
-- pg_net responses are written by a background worker in separate transactions,
-- so the queue / process / process-summaries phases MUST run as separate
-- statements (not inside a single function) to see each other's writes via MVCC.
-- That's why we schedule three pg_cron jobs offset by 1 minute each.
-- ============================================================================

CREATE TABLE IF NOT EXISTS performer_wiki_pending (
  tevo_performer_id  bigint,
  performer_name     text,
  stage              text,    -- 'search' | 'summary'
  search_request_id  bigint,
  summary_request_id bigint,
  fired_at           timestamptz DEFAULT now(),
  resolved_at        timestamptz,
  PRIMARY KEY (tevo_performer_id, stage)
);

-- (1) Fire opensearch calls for unmapped performers.
CREATE OR REPLACE FUNCTION queue_performer_wiki_searches(p_limit int DEFAULT 50)
RETURNS int AS $$
DECLARE
  r RECORD;
  v_req_id bigint;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT e.primary_performer_id AS pid, e.primary_performer_name AS pname
    FROM events e
    LEFT JOIN performer_wikipedia pw ON pw.tevo_performer_id = e.primary_performer_id
                                    AND pw.wiki_pageid IS NOT NULL
    LEFT JOIN performer_wiki_pending pwp
      ON pwp.tevo_performer_id = e.primary_performer_id
     AND pwp.fired_at > now() - interval '10 minutes'
    WHERE e.primary_performer_id IS NOT NULL
      AND e.primary_performer_name IS NOT NULL
      AND pw.tevo_performer_id IS NULL
      AND pwp.tevo_performer_id IS NULL
    ORDER BY e.primary_performer_id
    LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://en.wikipedia.org/w/api.php',
      params := jsonb_build_object(
        'action', 'opensearch', 'namespace', '0', 'limit', '1',
        'format', 'json', 'search', r.pname
      ),
      headers := jsonb_build_object(
        'User-Agent', 'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
        'Accept', 'application/json'
      ),
      timeout_milliseconds := 12000
    ) INTO v_req_id;

    INSERT INTO performer_wiki_pending(
      tevo_performer_id, performer_name, stage, search_request_id, fired_at
    ) VALUES (r.pid, r.pname, 'search', v_req_id, now())
    ON CONFLICT (tevo_performer_id, stage) DO UPDATE SET
      search_request_id = EXCLUDED.search_request_id,
      fired_at = now(), resolved_at = NULL;

    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- (2) Process search responses; fire summary fetches for hits.
DROP FUNCTION IF EXISTS process_performer_wiki_searches();
CREATE FUNCTION process_performer_wiki_searches()
RETURNS TABLE(processed int, hits int, misses int, retries int, summary_fired int) AS $$
DECLARE
  r RECORD;
  v_body jsonb;
  v_title text;
  v_summary_req_id bigint;
  v_processed int := 0; v_hits int := 0; v_misses int := 0;
  v_retries int := 0; v_sum_fired int := 0;
BEGIN
  FOR r IN
    SELECT pwp.tevo_performer_id, pwp.performer_name, pwp.search_request_id,
           h.content, h.status_code
    FROM performer_wiki_pending pwp
    JOIN net._http_response h ON h.id = pwp.search_request_id
    WHERE pwp.stage = 'search' AND pwp.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;

    IF r.status_code = 429 THEN
      DELETE FROM performer_wiki_pending
        WHERE tevo_performer_id = r.tevo_performer_id AND stage = 'search';
      v_retries := v_retries + 1;
      CONTINUE;
    END IF;

    IF r.status_code <> 200 THEN
      INSERT INTO performer_wikipedia(
        tevo_performer_id, performer_name, is_rejected, reject_reason,
        match_method, last_refreshed_at
      ) VALUES (r.tevo_performer_id, r.performer_name, true,
                'opensearch HTTP ' || r.status_code, 'rejected', now())
      ON CONFLICT (tevo_performer_id) DO UPDATE SET
        is_rejected = true, reject_reason = EXCLUDED.reject_reason,
        last_refreshed_at = now(), updated_at = now();
      UPDATE performer_wiki_pending SET resolved_at = now()
        WHERE tevo_performer_id = r.tevo_performer_id AND stage = 'search';
      v_misses := v_misses + 1;
      CONTINUE;
    END IF;

    BEGIN v_body := r.content::jsonb;
    EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
    v_title := NULL;
    IF v_body IS NOT NULL AND jsonb_typeof(v_body) = 'array' THEN
      v_title := COALESCE(v_body->1->>0, NULL);
    END IF;

    IF v_title IS NOT NULL AND length(v_title) > 0 THEN
      v_hits := v_hits + 1;
      SELECT net.http_get(
        url := 'https://en.wikipedia.org/api/rest_v1/page/summary/' ||
               replace(v_title, ' ', '_'),
        headers := jsonb_build_object(
          'User-Agent', 'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
          'Accept', 'application/json'
        ),
        timeout_milliseconds := 12000
      ) INTO v_summary_req_id;

      INSERT INTO performer_wiki_pending(
        tevo_performer_id, performer_name, stage, summary_request_id, fired_at
      ) VALUES (r.tevo_performer_id, r.performer_name, 'summary', v_summary_req_id, now())
      ON CONFLICT (tevo_performer_id, stage) DO UPDATE SET
        summary_request_id = EXCLUDED.summary_request_id,
        fired_at = now(), resolved_at = NULL;

      INSERT INTO performer_wikipedia(
        tevo_performer_id, performer_name, wiki_title,
        match_method, match_confidence, last_refreshed_at
      ) VALUES (r.tevo_performer_id, r.performer_name, v_title,
                'search_top', 0.7, now())
      ON CONFLICT (tevo_performer_id) DO UPDATE SET
        wiki_title = EXCLUDED.wiki_title,
        last_refreshed_at = now(), updated_at = now();

      v_sum_fired := v_sum_fired + 1;
      PERFORM pg_sleep(0.5);
    ELSE
      v_misses := v_misses + 1;
      INSERT INTO performer_wikipedia(
        tevo_performer_id, performer_name, is_rejected, reject_reason,
        match_method, last_refreshed_at
      ) VALUES (r.tevo_performer_id, r.performer_name, true,
                'opensearch returned no hits', 'rejected', now())
      ON CONFLICT (tevo_performer_id) DO UPDATE SET
        is_rejected = true, reject_reason = EXCLUDED.reject_reason,
        last_refreshed_at = now(), updated_at = now();
    END IF;

    UPDATE performer_wiki_pending SET resolved_at = now()
      WHERE tevo_performer_id = r.tevo_performer_id AND stage = 'search';
  END LOOP;

  RETURN QUERY SELECT v_processed, v_hits, v_misses, v_retries, v_sum_fired;
END;
$$ LANGUAGE plpgsql;

-- (3) Process summary responses; finalize performer_wikipedia rows.
CREATE OR REPLACE FUNCTION process_performer_wiki_summaries()
RETURNS int AS $$
DECLARE
  r RECORD; v_body jsonb; v_count int := 0;
BEGIN
  FOR r IN
    SELECT pwp.tevo_performer_id, pwp.summary_request_id, h.content, h.status_code
    FROM performer_wiki_pending pwp
    JOIN net._http_response h ON h.id = pwp.summary_request_id
    WHERE pwp.stage = 'summary' AND pwp.resolved_at IS NULL
  LOOP
    v_count := v_count + 1;

    IF r.status_code = 429 THEN
      DELETE FROM performer_wiki_pending
        WHERE tevo_performer_id = r.tevo_performer_id AND stage = 'summary';
      CONTINUE;
    END IF;

    BEGIN v_body := r.content::jsonb;
    EXCEPTION WHEN OTHERS THEN v_body := NULL; END;

    IF r.status_code = 200 AND v_body IS NOT NULL THEN
      UPDATE performer_wikipedia SET
        wiki_pageid = COALESCE((v_body->>'pageid')::bigint, wiki_pageid),
        wiki_title  = COALESCE(v_body->>'title', wiki_title),
        wiki_url    = COALESCE(v_body->'content_urls'->'desktop'->>'page',
                               'https://en.wikipedia.org/wiki/' ||
                               replace(COALESCE(v_body->>'title', wiki_title), ' ', '_')),
        description = v_body->>'description',
        extract     = v_body->>'extract',
        image_url   = v_body->'thumbnail'->>'source',
        match_method = 'search_top_summary',
        match_confidence = 0.85,
        last_refreshed_at = now(),
        raw_summary_jsonb = v_body,
        is_rejected = false,
        updated_at = now()
      WHERE tevo_performer_id = r.tevo_performer_id;
    ELSIF r.status_code = 404 THEN
      UPDATE performer_wikipedia SET
        is_rejected = true, reject_reason = 'summary 404',
        match_method = 'rejected', last_refreshed_at = now(), updated_at = now()
      WHERE tevo_performer_id = r.tevo_performer_id;
    END IF;

    UPDATE performer_wiki_pending SET resolved_at = now()
      WHERE tevo_performer_id = r.tevo_performer_id AND stage = 'summary';
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Schedule: 3 pg_cron jobs offset by 1 min so MVCC sees each other's writes.
SELECT cron.schedule(
  'performer_wiki_queue_searches_5min',
  '*/5 * * * *',
  $$ SELECT queue_performer_wiki_searches(20); $$
);
SELECT cron.schedule(
  'performer_wiki_process_searches_5min',
  '1-59/5 * * * *',
  $$ SELECT process_performer_wiki_searches(); $$
);
SELECT cron.schedule(
  'performer_wiki_process_summaries_5min',
  '2-59/5 * * * *',
  $$ SELECT process_performer_wiki_summaries(); $$
);
