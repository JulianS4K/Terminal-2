-- ============================================================================
-- Migration 20260708151000 — Athlete → Wikipedia matching pipeline
--
-- Lane:     data plane (A1)
-- Touches:  athlete_wikipedia (new), athlete_wiki_pending (new),
--           queue/process/sweep functions (new), 4 cron jobs (gated, operator-
--           approved 2026-07-08)
--
-- Operator directive step 3: "map wiki where available." Mirrors the proven
-- performer→wiki pg_net pipeline (20260509170000) — a two-stage async flow
-- (search -> REST summary) tracked in a pending table, read back from
-- net._http_response, split across separate cron ticks so MVCC lets each stage
-- see the prior stage's committed writes.
--
-- KEY DIVERGENCE — collision handling: athletes have heavy name collisions
-- (multiple "Josh Allen"). The performer pipeline used a bare limit=1 OpenSearch
-- with zero disambiguation. Here the search query is BIASED with a per-league
-- sport hint ("Josh Allen American football"), and the summary is VALIDATED
-- against the athlete's sport keywords — a summary whose description/extract
-- doesn't mention the sport is kept but flagged low-confidence + unverified.
--
-- Priority: brand athletes (the rostered players that feed the zone feature
-- store) are matched first, highest brand_score first.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (0) sport hints
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _athlete_sport_hint(p_league text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_league
    WHEN 'NFL' THEN 'American football' WHEN 'NCAAF' THEN 'American football'
    WHEN 'NBA' THEN 'basketball player' WHEN 'WNBA' THEN 'basketball player'
    WHEN 'MLB' THEN 'baseball'          WHEN 'NHL'  THEN 'ice hockey'
    WHEN 'MLS' THEN 'soccer'            WHEN 'World Cup' THEN 'soccer'
    ELSE NULL END
$$;

-- Sport keywords used to VALIDATE a summary belongs to the right athlete.
CREATE OR REPLACE FUNCTION _athlete_sport_keywords(p_league text)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_league
    WHEN 'NFL'  THEN ARRAY['american football','football']
    WHEN 'NCAAF' THEN ARRAY['american football','football']
    WHEN 'NBA'  THEN ARRAY['basketball']
    WHEN 'WNBA' THEN ARRAY['basketball']
    WHEN 'MLB'  THEN ARRAY['baseball']
    WHEN 'NHL'  THEN ARRAY['hockey']
    WHEN 'MLS'  THEN ARRAY['soccer','footballer','football']
    WHEN 'World Cup' THEN ARRAY['soccer','footballer','football']
    ELSE NULL END
$$;

-- ----------------------------------------------------------------------------
-- (1) tables
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS athlete_wikipedia (
  espn_athlete_id   text PRIMARY KEY REFERENCES athlete_pages(espn_athlete_id) ON DELETE CASCADE,
  athlete_name      text,
  espn_league       text,
  wiki_title        text,
  wiki_pageid       bigint,
  wiki_url          text,
  wiki_lang         text DEFAULT 'en',
  description       text,
  extract           text,
  image_url         text,
  match_confidence  numeric(3,2),
  match_method      text,
  is_rejected       boolean DEFAULT false,
  reject_reason     text,
  raw_summary_jsonb jsonb,
  last_refreshed_at timestamptz,
  created_at        timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS athlete_wikipedia_unmatched_idx
  ON athlete_wikipedia(espn_athlete_id) WHERE wiki_pageid IS NULL AND NOT is_rejected;
GRANT SELECT ON athlete_wikipedia TO anon;

CREATE TABLE IF NOT EXISTS athlete_wiki_pending (
  espn_athlete_id     text NOT NULL,
  stage               text NOT NULL,   -- 'search' | 'summary'
  search_request_id   bigint,
  summary_request_id  bigint,
  search_term         text,
  fired_at            timestamptz DEFAULT now(),
  resolved_at         timestamptz,
  PRIMARY KEY (espn_athlete_id, stage)
);
CREATE INDEX IF NOT EXISTS athlete_wiki_pending_unresolved_idx
  ON athlete_wiki_pending(stage) WHERE resolved_at IS NULL;

-- Shared HTTP header (identifies us to Wikipedia per their UA policy).
-- ----------------------------------------------------------------------------
-- (2) ENQUEUE — fire an OpenSearch-with-sport-hint per unmatched athlete
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION queue_athlete_wiki_searches(p_limit int DEFAULT 40)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_req bigint; v_term text; v_count int := 0;
  v_ua jsonb := jsonb_build_object('User-Agent',
    'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
    'Accept','application/json');
BEGIN
  FOR r IN
    SELECT p.espn_athlete_id, p.full_name, p.espn_league, ab.brand_score
    FROM athlete_pages p
    LEFT JOIN espn_athlete_brand ab ON ab.espn_athlete_id = p.espn_athlete_id
    WHERE p.full_name IS NOT NULL AND length(trim(p.full_name)) > 2
      AND NOT EXISTS (SELECT 1 FROM athlete_wikipedia w WHERE w.espn_athlete_id = p.espn_athlete_id)
      AND NOT EXISTS (SELECT 1 FROM athlete_wiki_pending pd
                       WHERE pd.espn_athlete_id = p.espn_athlete_id AND pd.fired_at > now() - interval '1 hour')
    ORDER BY (ab.brand_score IS NULL), ab.brand_score DESC, p.espn_athlete_id
    LIMIT p_limit
  LOOP
    v_term := r.full_name || COALESCE(' ' || _athlete_sport_hint(r.espn_league), '');
    SELECT net.http_get(
      url := 'https://en.wikipedia.org/w/api.php',
      params := jsonb_build_object('action','query','list','search','format','json',
                                   'srlimit','1','srsearch', v_term),
      headers := v_ua, timeout_milliseconds := 12000
    ) INTO v_req;
    INSERT INTO athlete_wiki_pending(espn_athlete_id, stage, search_request_id, search_term)
    VALUES (r.espn_athlete_id, 'search', v_req, v_term)
    ON CONFLICT (espn_athlete_id, stage) DO UPDATE
      SET search_request_id = EXCLUDED.search_request_id, search_term = EXCLUDED.search_term,
          fired_at = now(), resolved_at = NULL;
    v_count := v_count + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_count;
END $$;

-- ----------------------------------------------------------------------------
-- (3) PROCESS search -> pick title, fire summary, write provisional row
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_athlete_wiki_searches()
RETURNS TABLE(processed int, hits int, misses int, summary_fired int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_body jsonb; v_title text; v_sreq bigint;
  v_ua jsonb := jsonb_build_object('User-Agent',
    'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
    'Accept','application/json');
  v_p int := 0; v_h int := 0; v_m int := 0; v_s int := 0;
BEGIN
  FOR r IN
    SELECT pd.espn_athlete_id, pd.search_term, h.content, h.status_code,
           ap.full_name, ap.espn_league
    FROM athlete_wiki_pending pd
    JOIN net._http_response h ON h.id = pd.search_request_id
    JOIN athlete_pages ap ON ap.espn_athlete_id = pd.espn_athlete_id
    WHERE pd.stage = 'search' AND pd.resolved_at IS NULL
  LOOP
    v_p := v_p + 1;
    IF r.status_code = 429 THEN
      DELETE FROM athlete_wiki_pending WHERE espn_athlete_id = r.espn_athlete_id AND stage = 'search';
      CONTINUE;  -- retry next tick
    END IF;
    IF r.status_code <> 200 THEN
      INSERT INTO athlete_wikipedia(espn_athlete_id, athlete_name, espn_league, is_rejected, reject_reason, match_method, updated_at)
      VALUES (r.espn_athlete_id, r.full_name, r.espn_league, true, 'search HTTP ' || r.status_code, 'rejected', now())
      ON CONFLICT (espn_athlete_id) DO UPDATE SET is_rejected=true, reject_reason=EXCLUDED.reject_reason, updated_at=now();
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='search';
      v_m := v_m + 1; CONTINUE;
    END IF;
    BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
    v_title := v_body -> 'query' -> 'search' -> 0 ->> 'title';
    IF v_title IS NULL THEN
      INSERT INTO athlete_wikipedia(espn_athlete_id, athlete_name, espn_league, is_rejected, reject_reason, match_method, updated_at)
      VALUES (r.espn_athlete_id, r.full_name, r.espn_league, true, 'search returned no hits', 'rejected', now())
      ON CONFLICT (espn_athlete_id) DO UPDATE SET is_rejected=true, reject_reason=EXCLUDED.reject_reason, updated_at=now();
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='search';
      v_m := v_m + 1; CONTINUE;
    END IF;
    -- fire the summary request
    SELECT net.http_get(
      url := 'https://en.wikipedia.org/api/rest_v1/page/summary/' || replace(v_title, ' ', '_'),
      headers := v_ua, timeout_milliseconds := 12000
    ) INTO v_sreq;
    INSERT INTO athlete_wiki_pending(espn_athlete_id, stage, summary_request_id, search_term)
    VALUES (r.espn_athlete_id, 'summary', v_sreq, r.search_term)
    ON CONFLICT (espn_athlete_id, stage) DO UPDATE
      SET summary_request_id = EXCLUDED.summary_request_id, fired_at = now(), resolved_at = NULL;
    -- provisional wiki row (title only)
    INSERT INTO athlete_wikipedia(espn_athlete_id, athlete_name, espn_league, wiki_title,
                                  match_confidence, match_method, is_rejected, updated_at)
    VALUES (r.espn_athlete_id, r.full_name, r.espn_league, v_title, 0.6, 'search_top', false, now())
    ON CONFLICT (espn_athlete_id) DO UPDATE
      SET wiki_title=EXCLUDED.wiki_title, match_confidence=0.6, match_method='search_top',
          is_rejected=false, reject_reason=NULL, updated_at=now();
    UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='search';
    v_h := v_h + 1; v_s := v_s + 1;
  END LOOP;
  RETURN QUERY SELECT v_p, v_h, v_m, v_s;
END $$;

-- ----------------------------------------------------------------------------
-- (4) PROCESS summary -> write final page + validate sport
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_athlete_wiki_summaries()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_body jsonb; v_kw text[]; v_hay text; v_ok boolean; v_conf numeric; v_method text;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT pd.espn_athlete_id, h.content, h.status_code, w.espn_league
    FROM athlete_wiki_pending pd
    JOIN net._http_response h ON h.id = pd.summary_request_id
    LEFT JOIN athlete_wikipedia w ON w.espn_athlete_id = pd.espn_athlete_id
    WHERE pd.stage = 'summary' AND pd.resolved_at IS NULL
  LOOP
    IF r.status_code = 429 THEN
      DELETE FROM athlete_wiki_pending WHERE espn_athlete_id = r.espn_athlete_id AND stage = 'summary';
      CONTINUE;
    END IF;
    IF r.status_code = 404 THEN
      UPDATE athlete_wikipedia SET is_rejected=true, reject_reason='summary 404', match_method='rejected', updated_at=now()
        WHERE espn_athlete_id = r.espn_athlete_id;
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
      CONTINUE;
    END IF;
    IF r.status_code <> 200 THEN
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
      CONTINUE;
    END IF;
    BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
    IF v_body IS NULL THEN
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
      CONTINUE;
    END IF;
    -- sport validation
    v_kw := _athlete_sport_keywords(r.espn_league);
    v_hay := lower(coalesce(v_body->>'description','') || ' ' || coalesce(v_body->>'extract',''));
    v_ok := v_kw IS NULL OR EXISTS (SELECT 1 FROM unnest(v_kw) k WHERE v_hay LIKE '%'||k||'%');
    v_conf   := CASE WHEN v_ok THEN 0.9 ELSE 0.5 END;
    v_method := CASE WHEN v_ok THEN 'summary_sport_verified' ELSE 'summary_unverified' END;

    UPDATE athlete_wikipedia SET
      wiki_pageid = (v_body->>'pageid')::bigint,
      wiki_url    = v_body->'content_urls'->'desktop'->>'page',
      description = v_body->>'description',
      extract     = v_body->>'extract',
      image_url   = v_body->'thumbnail'->>'source',
      match_confidence = v_conf, match_method = v_method,
      is_rejected = false, reject_reason = NULL,
      raw_summary_jsonb = v_body, last_refreshed_at = now(), updated_at = now()
    WHERE espn_athlete_id = r.espn_athlete_id;
    UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- ----------------------------------------------------------------------------
-- (5) sweep resolved pending rows
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION athlete_wiki_pending_sweep()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM athlete_wiki_pending WHERE resolved_at IS NOT NULL OR fired_at < now() - interval '1 day';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ----------------------------------------------------------------------------
-- (6) crons — three stages offset by a minute, every 30 min; daily sweep
-- ----------------------------------------------------------------------------
-- 15/tick: Wikipedia caps effective throughput ~10/tick, so a smaller batch
-- keeps the hit/429-retry ratio healthy (429s are auto-retried next tick).
SELECT cron.schedule('athlete_wiki_queue_searches',   '*/30 * * * *',    $$ SELECT public.queue_athlete_wiki_searches(15); $$);
SELECT cron.schedule('athlete_wiki_process_searches', '2-59/30 * * * *', $$ SELECT public.process_athlete_wiki_searches(); $$);
SELECT cron.schedule('athlete_wiki_process_summaries','4-59/30 * * * *', $$ SELECT public.process_athlete_wiki_summaries(); $$);
SELECT cron.schedule('athlete_wiki_pending_sweep',    '45 3 * * *',      $$ SELECT public.athlete_wiki_pending_sweep(); $$);
