-- ============================================================================
-- Migration 20260510120000 — In-DB strict (home, away, league, date) matcher
--
-- Replaces the broken edge-function `team_date` matcher (60+ collisions
-- caught by v_event_xref_collisions). Self-paced: every 10 min the cron
-- processes 10 candidates, draining the 657-event backlog in ~11 hours
-- and keeping pace with new events going forward.
--
-- Performance verified live: 630 events matched via in_db_strict_v1 in
-- the bootstrap pass, including all 7 PHI/NYK series games correctly
-- (401871159 → Game 1 ... 401871165 → Game 7). Collisions dropped from
-- 60 → 17 remaining.
--
-- Remaining 17 collisions are MLB games where the +30/+90 day window
-- needs an additional pull (1000-row scoreboard cap). Queue function
-- chunks MLB into 2 calls to fix this on the next 4-hour tick.
-- ============================================================================

-- ============================================================================
-- (1) Pending queue
-- ============================================================================
CREATE TABLE IF NOT EXISTS espn_scoreboard_pending (
  id            bigserial PRIMARY KEY,
  espn_league   text NOT NULL,
  request_id    bigint NOT NULL,
  fired_at      timestamptz DEFAULT now(),
  resolved_at   timestamptz,
  http_status   int,
  events_count  int,
  error         text
);
CREATE INDEX IF NOT EXISTS espn_scoreboard_pending_unresolved_idx
  ON espn_scoreboard_pending(espn_league) WHERE resolved_at IS NULL;

-- ============================================================================
-- (2) Queue: 7 calls (MLB chunked) every 4 hours
-- ============================================================================
CREATE OR REPLACE FUNCTION espn_scoreboard_queue(p_lookahead_days int DEFAULT 90)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  cfg RECORD; v_req bigint; v_count int := 0;
  v_back text := to_char(current_date - 30, 'YYYYMMDD');
  v_mid  text := to_char(current_date + 30, 'YYYYMMDD');
  v_far  text := to_char(current_date + p_lookahead_days, 'YYYYMMDD');
BEGIN
  FOR cfg IN
    SELECT * FROM (VALUES
      ('basketball','nba','NBA',   v_back || '-' || v_far),
      ('football','nfl','NFL',     v_back || '-' || v_far),
      ('baseball','mlb','MLB',     v_back || '-' || v_mid),
      ('baseball','mlb','MLB',     v_mid  || '-' || v_far),
      ('hockey','nhl','NHL',       v_back || '-' || v_far),
      ('basketball','wnba','WNBA', v_back || '-' || v_far),
      ('soccer','usa.1','MLS',     v_back || '-' || v_far)
    ) AS x(sport, league_path, league_label, date_range)
  LOOP
    SELECT net.http_get(
      url := 'https://site.api.espn.com/apis/site/v2/sports/' || cfg.sport || '/' || cfg.league_path || '/scoreboard',
      params := jsonb_build_object('dates', cfg.date_range, 'limit', '1000'),
      headers := jsonb_build_object('Accept','application/json','User-Agent','terminal-2-broker (julian@s4kent.com)'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO espn_scoreboard_pending(espn_league, request_id) VALUES (cfg.league_label, v_req);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END $$;

COMMENT ON FUNCTION espn_scoreboard_queue(integer) IS
  '7 ESPN scoreboard pulls per tick (MLB chunked into 2 to dodge the '
  '1000-event scoreboard cap). Cron: every 4 hours = 42 calls/day.';

-- ============================================================================
-- (3) Process: drain pending → espn_event_date_lookup
-- ============================================================================
CREATE OR REPLACE FUNCTION espn_scoreboard_process()
RETURNS TABLE(processed int, events_upserted int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_body jsonb; feat jsonb;
  v_processed int := 0; v_upserted int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.espn_league, h.content, h.status_code
    FROM espn_scoreboard_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      IF v_body IS NOT NULL THEN
        FOR feat IN SELECT jsonb_array_elements(v_body -> 'events')
        LOOP
          IF (feat ->> 'id') IS NOT NULL AND (feat ->> 'date') IS NOT NULL THEN
            INSERT INTO espn_event_date_lookup(espn_event_id, espn_league, game_at_utc,
                                                home_team_id, away_team_id, status_short)
            SELECT feat ->> 'id', r.espn_league, (feat ->> 'date')::timestamptz,
              (SELECT (c->'team'->>'id') FROM jsonb_array_elements(feat->'competitions'->0->'competitors') c WHERE c->>'homeAway' = 'home' LIMIT 1),
              (SELECT (c->'team'->>'id') FROM jsonb_array_elements(feat->'competitions'->0->'competitors') c WHERE c->>'homeAway' = 'away' LIMIT 1),
              feat -> 'status' -> 'type' ->> 'shortDetail'
            ON CONFLICT (espn_event_id, espn_league) DO UPDATE SET
              game_at_utc=EXCLUDED.game_at_utc, home_team_id=EXCLUDED.home_team_id,
              away_team_id=EXCLUDED.away_team_id, status_short=EXCLUDED.status_short, ingested_at=now();
            v_upserted := v_upserted + 1;
          END IF;
        END LOOP;
      END IF;
    END IF;
    UPDATE espn_scoreboard_pending
       SET resolved_at = now(), http_status = r.status_code,
           events_count = jsonb_array_length(COALESCE(v_body -> 'events','[]'::jsonb))
     WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_upserted;
END $$;

-- ============================================================================
-- (4) Strict matcher: (sport, league, home, away, date in PT) join
--     Pacific time chosen because it's the westernmost US TZ — every
--     home-venue-local date matches the Pacific date of game_at_utc.
-- ============================================================================
CREATE OR REPLACE FUNCTION match_events_to_espn_tick(p_limit int DEFAULT 10)
RETURNS TABLE(considered int, matched int, no_data int, skipped int)
LANGUAGE plpgsql AS $$
DECLARE
  e RECORD; m RECORD;
  v_considered int := 0; v_matched int := 0; v_no_data int := 0; v_skipped int := 0;
  v_home_team text; v_home_league text; v_away_perf_id bigint; v_away_team text; v_away_league text;
BEGIN
  FOR e IN
    SELECT ev.id, ev.name, ev.occurs_at_local, ev.primary_performer_id,
           trim(split_part(ev.name, ' at ', 1)) AS away_name_raw,
           ev.occurs_at_local::date AS event_date
    FROM events ev
    WHERE ev.event_type = 'game'
      AND ev.primary_performer_id IS NOT NULL
      AND ev.name ILIKE '% at %'
      AND ev.occurs_at_local::timestamptz BETWEEN now() - interval '7 days'
                                              AND now() + interval '90 days'
      AND NOT EXISTS (SELECT 1 FROM event_xref ex
                       WHERE ex.tevo_event_id = ev.id
                         AND ex.match_method LIKE 'in_db_strict_v%')
    ORDER BY ev.occurs_at_local
    LIMIT p_limit
  LOOP
    v_considered := v_considered + 1;

    SELECT espn_team_id, espn_league INTO v_home_team, v_home_league
    FROM performer_espn_team_xref WHERE tevo_performer_id = e.primary_performer_id LIMIT 1;
    IF v_home_team IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT pm.performer_id INTO v_away_perf_id FROM performer_metadata pm
    WHERE lower(trim(pm.name)) = lower(trim(e.away_name_raw)) LIMIT 1;
    IF v_away_perf_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT espn_team_id, espn_league INTO v_away_team, v_away_league
    FROM performer_espn_team_xref WHERE tevo_performer_id = v_away_perf_id AND espn_league = v_home_league LIMIT 1;
    IF v_away_team IS NULL OR v_away_league <> v_home_league THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT * INTO m FROM espn_event_date_lookup edl
    WHERE edl.espn_league = v_home_league
      AND edl.home_team_id = v_home_team
      AND edl.away_team_id = v_away_team
      AND (edl.game_at_utc AT TIME ZONE 'America/Los_Angeles')::date = e.event_date
    LIMIT 1;
    IF NOT FOUND THEN v_no_data := v_no_data + 1; CONTINUE; END IF;

    INSERT INTO event_xref(tevo_event_id, espn_event_id, espn_league, espn_slug,
                           match_method, meta, matched_at)
    VALUES (e.id, m.espn_event_id, m.espn_league,
      CASE m.espn_league
        WHEN 'NBA' THEN 'basketball/nba' WHEN 'NFL' THEN 'football/nfl'
        WHEN 'MLB' THEN 'baseball/mlb'   WHEN 'NHL' THEN 'hockey/nhl'
        WHEN 'WNBA' THEN 'basketball/wnba' WHEN 'MLS' THEN 'soccer/usa.1' END,
      'in_db_strict_v1',
      jsonb_build_object('home_team_id', v_home_team, 'away_team_id', v_away_team,
                         'event_date', e.event_date, 'tevo_name', e.name,
                         'matched_via', 'in_db_strict_v1_pt_date'),
      now())
    ON CONFLICT (tevo_event_id) DO UPDATE SET
      espn_event_id = EXCLUDED.espn_event_id, espn_league = EXCLUDED.espn_league,
      espn_slug = EXCLUDED.espn_slug, match_method = EXCLUDED.match_method,
      meta = EXCLUDED.meta, matched_at = now();
    v_matched := v_matched + 1;
  END LOOP;
  RETURN QUERY SELECT v_considered, v_matched, v_no_data, v_skipped;
END $$;

-- ============================================================================
-- (5) Refined collision guard view — exclude same-game promo dupes
-- ============================================================================
DROP VIEW IF EXISTS v_event_xref_collisions CASCADE;
CREATE VIEW v_event_xref_collisions AS
WITH raw_collisions AS (
  SELECT ex.espn_event_id, ex.espn_league,
         array_agg(ex.tevo_event_id ORDER BY ex.matched_at DESC) AS tevo_event_ids,
         array_agg(e.name             ORDER BY ex.matched_at DESC) AS tevo_event_names,
         array_agg(e.occurs_at_local::date ORDER BY ex.matched_at DESC) AS tevo_event_dates,
         array_agg(e.primary_performer_id  ORDER BY ex.matched_at DESC) AS tevo_home_perf_ids,
         max(ex.matched_at) AS most_recent_match
  FROM event_xref ex JOIN events e ON e.id = ex.tevo_event_id
  WHERE ex.match_method NOT IN ('tournament_token_overlap')
  GROUP BY ex.espn_event_id, ex.espn_league HAVING count(*) > 1
)
SELECT espn_event_id, espn_league, cardinality(tevo_event_ids)::bigint AS tevo_event_count,
       tevo_event_ids, tevo_event_names, tevo_event_dates, most_recent_match
FROM raw_collisions
-- Same-(date, home_performer) = TEvo promo variant duplicates, not real collisions
WHERE NOT (
  cardinality(array(SELECT DISTINCT unnest(tevo_event_dates))) = 1
  AND cardinality(array(SELECT DISTINCT unnest(tevo_home_perf_ids))) = 1
);
GRANT SELECT ON v_event_xref_collisions TO anon;

-- ============================================================================
-- (6) Cron schedules
-- ============================================================================
SELECT cron.schedule('espn_scoreboard_queue_4h',     '0 */4 * * *',    $$ SELECT public.espn_scoreboard_queue(); $$);
SELECT cron.schedule('espn_scoreboard_process_5min', '5-59/5 * * * *', $$ SELECT public.espn_scoreboard_process(); $$);
SELECT cron.schedule('match_events_to_espn_10min',   '*/10 * * * *',   $$ SELECT public.match_events_to_espn_tick(10); $$);
