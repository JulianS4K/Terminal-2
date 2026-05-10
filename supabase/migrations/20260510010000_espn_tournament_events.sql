-- ============================================================================
-- Migration 20260510010000 — ESPN tournament events for F1 / Tennis / Golf / LIV
--
-- Per directive (2026-05-09): "we earlier added F1, tennis and golf events,
-- map those to their respective ESPN sports".
--
-- Phase 1 added 213 upcoming tournament events to the events table via the
-- TEvo category-id pull (20 F1, ~50 golf, 170 tennis). NONE of them had an
-- event_xref to ESPN today — espn_event_snapshots is team-game-only
-- (MLB/NBA/NHL/WNBA). This migration adds the individual-sport side.
--
-- ----------------------------------------------------------------------------
-- DATA-DICTIONARY MAP
-- ----------------------------------------------------------------------------
-- TEvo side                          ESPN side                        Match
-- ---------------------------------- -------------------------------- -------
-- events.id                          espn_tournament_events.id        event_xref
-- events.name (e.g. "Wimbledon -     name (e.g. "Wimbledon            tokens
--   Quarterfinals - Court 1")          Championships")                  overlap
-- events.occurs_at_local::date       date IN [start_date, end_date]   ±1d window
--
-- ESPN endpoint shape (6 leagues; date-range scoreboard returns full season):
--   /sports/racing/f1/scoreboard?dates=YYYYMMDD-YYYYMMDD     →  19 races/yr
--   /sports/tennis/atp/scoreboard?...                        →  ~37 tournaments
--   /sports/tennis/wta/scoreboard?...                        →  ~53 tournaments
--   /sports/golf/pga/scoreboard?...                          →  ~31 tournaments
--   /sports/golf/lpga/scoreboard?...                         →  ~20 tournaments
--   /sports/golf/liv/scoreboard?...                          →   ~9 events
--
-- ESPN scoreboard caps date ranges at ~1 year — using 240-day lookahead.
--
-- ----------------------------------------------------------------------------
-- WHY NOT REUSE espn_event_snapshots
-- ----------------------------------------------------------------------------
-- espn_event_snapshots is shaped around team games (home_team_id, away_team_id,
-- home_score, away_score, spread, etc.). Tournament events are 14-day
-- multi-round affairs with a field of 100+ players, no home/away. Wedging
-- tournaments into that table would force NULLs on every team/score column.
-- Better: parallel `espn_tournament_events` table.
--
-- event_xref is REUSED — same (tevo_event_id, espn_event_id, espn_league)
-- linkage works for both team games and tournament sessions.
--
-- ----------------------------------------------------------------------------
-- BUGS CAUGHT DURING VERIFICATION (FIXED INLINE)
-- ----------------------------------------------------------------------------
-- 1. ESPN scoreboard returns 400 for date ranges > ~1 year. Default lookahead
--    set to 240 days (8 months).
-- 2. Substring matching fails on sponsor prefixes ("Lenovo Canadian Grand Prix"
--    vs TEvo's "Canadian Grand Prix"). Switched to token-overlap with sponsor
--    brand stop list.
-- 3. plpgsql `IF m IS NOT NULL` returns FALSE when ANY column of the RECORD
--    is NULL (e.g. end_date NULL on F1). Use `IF FOUND` instead.
-- 4. `event_xref.espn_slug` is NOT NULL — derive from `sport/league` like
--    "racing/f1", "tennis/atp", "golf/liv".
-- 5. PostgreSQL POSIX regex uses `\m...\M` for word boundaries, not `\b`.
-- 6. Token-overlap stop list initially too aggressive — stripped `open` and
--    `championship` which are signal words for tennis/golf. Tightened.
-- ============================================================================

-- ============================================================================
-- (1) espn_tournament_events — the ESPN-side table
-- ============================================================================

CREATE TABLE IF NOT EXISTS espn_tournament_events (
  espn_event_id    text PRIMARY KEY,
  espn_sport       text NOT NULL,                   -- 'racing' | 'tennis' | 'golf'
  espn_league      text NOT NULL,                   -- 'f1' | 'atp' | 'wta' | 'pga' | 'lpga' | 'liv'
  name             text NOT NULL,
  short_name       text,
  start_date       timestamptz NOT NULL,
  end_date         timestamptz,
  state            text,                            -- 'pre' | 'in' | 'post'
  status_short     text,
  venue_name       text,
  venue_city       text,
  venue_state      text,
  venue_country    text,
  total_purse      numeric,                         -- golf
  defending_champ  text,                            -- tennis/golf
  field_size       int,                             -- golf
  course_name      text,                            -- golf
  circuit_name     text,                            -- f1
  raw_jsonb        jsonb,
  ingested_at      timestamptz DEFAULT now(),
  last_seen_at     timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS espn_tournament_events_league_idx ON espn_tournament_events(espn_league);
CREATE INDEX IF NOT EXISTS espn_tournament_events_start_idx  ON espn_tournament_events(start_date);
CREATE INDEX IF NOT EXISTS espn_tournament_events_end_idx    ON espn_tournament_events(end_date);

COMMENT ON TABLE espn_tournament_events IS
  'ESPN individual-sport tournament events (F1 races, tennis tournaments, '
  'golf tournaments). Parallel to espn_event_snapshots which is team-game '
  'shaped. One row per tournament; TEvo events are individual sessions '
  'within a tournament, mapped via event_xref.';

-- ============================================================================
-- (2) Pending queue (mirrors NWS / Open-Meteo pattern)
-- ============================================================================

CREATE TABLE IF NOT EXISTS espn_tournament_pending (
  id            bigserial PRIMARY KEY,
  espn_sport    text NOT NULL,
  espn_league   text NOT NULL,
  date_range    text NOT NULL,
  request_id    bigint NOT NULL,
  fired_at      timestamptz DEFAULT now(),
  resolved_at   timestamptz,
  http_status   int,
  events_count  int,
  error         text
);
CREATE INDEX IF NOT EXISTS espn_tournament_pending_unresolved_idx
  ON espn_tournament_pending(fired_at) WHERE resolved_at IS NULL;

-- ============================================================================
-- (3) Sport-from-name classifiers
-- ============================================================================

CREATE OR REPLACE FUNCTION classify_tournament_sport(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_name ~* '(grand prix|formula 1|^f1\s|^f1 -)'                          THEN 'f1'
    WHEN p_name ~* '\mliv golf\M'                                                  THEN 'liv'
    WHEN p_name ~* '(masters tournament|the masters|^pga |us open golf|the open champ|RBC|TPC|FedEx|presidents cup|ryder cup)' THEN 'pga'
    WHEN p_name ~* '(LPGA|womens golf|women''s golf|solheim cup)'                 THEN 'lpga'
    WHEN p_name ~* '(wimbledon|roland garros|french open|australian open|us open tennis|atp|wta|tennis|grand slam|laver cup|bnl d''italia|miami open tennis|indian wells|masters 1000|tennis open|davis cup|billie jean king cup)' THEN 'tennis'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION classify_tennis_tour(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_name ~* '(womens|women''s|wta|ladies)' THEN 'wta'
    WHEN p_name ~* '(mens|men''s|atp)'             THEN 'atp'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION normalize_tournament_name(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(trim(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(p_name,
              '\s*-\s*(day|round|session)\s*\d+.*$', '', 'gi'),
            '\s*-\s*(qualifying|practice|sprint|final|finals|semifinals|semifinal|quarterfinals|quarterfinal|round of \d+).*$', '', 'gi'),
          '\s*-\s*(mens|men''s|womens|women''s|mixed) (singles|doubles).*$', '', 'gi'),
        '\s*\(.*?\)\s*', ' ', 'g'),
      '\s+', ' ', 'g')
  ));
$$;

-- ============================================================================
-- (4) Token-overlap matcher (replaces the substring approach)
-- ============================================================================

CREATE OR REPLACE FUNCTION tournament_name_tokens(p_name text)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  WITH raw AS (
    SELECT regexp_split_to_table(
      lower(regexp_replace(coalesce(p_name,''), '[^a-z0-9 -]', ' ', 'gi')),
      '\s+'
    ) AS tok
  )
  SELECT array_agg(DISTINCT tok)
  FROM raw
  WHERE length(tok) >= 2
    AND tok NOT IN (
      -- Generic stops only — KEEP `open`, `championship`, `cup`, `prix`, `grand`
      'the','and','tour','of','for','at','to','by','de','du','la','el',
      'race','round','final','finals','semifinals','semifinal',
      'quarterfinals','quarterfinal','session','practice','sprint',
      'qualifying','tournament','classic','pres',
      'mens','men','womens','women','singles','doubles','day','rounds',
      'pass','ticket','tickets','mr','am','pm',
      'monday','tuesday','wednesday','thursday','friday','saturday','sunday',
      '2024','2025','2026','2027','2028',
      -- F1 sponsor brand prefixes
      'lenovo','crypto','com','pirelli','aws','heineken','msc','cruises',
      'singapore','airlines','qatar','airways','etihad','tag','heuer',
      -- Tennis sponsor noise
      'mutua','gonet','bitpanda','libema','terra','wortmann',
      'huzhou','jiangxi','trophée','clarins','solgironès','catalonia',
      -- Golf sponsor noise
      'truist','rbc','tpc','fedex','workday','byron','nelson','memorial',
      'cadillac','cj','schwab','solheim','oneflight'
    );
$$;

CREATE OR REPLACE FUNCTION tournament_match_score(p_tevo text, p_espn text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT cardinality(
    ARRAY(
      SELECT unnest(tournament_name_tokens(p_tevo))
      INTERSECT
      SELECT unnest(tournament_name_tokens(p_espn))
    )
  );
$$;

-- ============================================================================
-- (5) Queue: fires 6 league requests covering forward 240 days
-- ============================================================================

CREATE OR REPLACE FUNCTION espn_tournament_queue(p_lookahead_days int DEFAULT 240)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_start text := to_char(current_date - 7, 'YYYYMMDD');
  v_end   text := to_char(current_date + p_lookahead_days, 'YYYYMMDD');
  v_range text := v_start || '-' || v_end;
  v_req   bigint;
  v_count int := 0;
  cfg RECORD;
BEGIN
  FOR cfg IN
    SELECT * FROM (VALUES
      ('racing','f1','site.api.espn.com/apis/site/v2/sports/racing/f1/scoreboard'),
      ('tennis','atp','site.api.espn.com/apis/site/v2/sports/tennis/atp/scoreboard'),
      ('tennis','wta','site.api.espn.com/apis/site/v2/sports/tennis/wta/scoreboard'),
      ('golf','pga','site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard'),
      ('golf','lpga','site.api.espn.com/apis/site/v2/sports/golf/lpga/scoreboard'),
      ('golf','liv','site.api.espn.com/apis/site/v2/sports/golf/liv/scoreboard')
    ) AS x(sport, league, host_path)
  LOOP
    SELECT net.http_get(
      url := 'https://' || cfg.host_path,
      params := jsonb_build_object('dates', v_range),
      headers := jsonb_build_object(
        'Accept', 'application/json',
        'User-Agent', 'terminal-2-broker (julian@s4kent.com)'
      ),
      timeout_milliseconds := 20000
    ) INTO v_req;
    INSERT INTO espn_tournament_pending(espn_sport, espn_league, date_range, request_id)
    VALUES (cfg.sport, cfg.league, v_range, v_req);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.3);
  END LOOP;
  RETURN v_count;
END $$;

-- ============================================================================
-- (6) Process: parses scoreboard responses, upserts espn_tournament_events
-- ============================================================================

CREATE OR REPLACE FUNCTION espn_tournament_process()
RETURNS TABLE(processed int, events_upserted int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_body jsonb; feat jsonb; comp jsonb; venue jsonb;
  v_processed int := 0; v_upserted int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.espn_sport, p.espn_league, h.content, h.status_code
    FROM espn_tournament_pending p
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
          comp := COALESCE(feat -> 'competitions' -> 0, '{}'::jsonb);
          venue := COALESCE(comp -> 'venue', '{}'::jsonb);
          INSERT INTO espn_tournament_events(
            espn_event_id, espn_sport, espn_league,
            name, short_name,
            start_date, end_date, state, status_short,
            venue_name, venue_city, venue_state, venue_country,
            circuit_name, raw_jsonb, last_seen_at
          ) VALUES (
            feat ->> 'id', r.espn_sport, r.espn_league,
            feat ->> 'name', feat ->> 'shortName',
            (feat ->> 'date')::timestamptz,
            NULLIF(feat ->> 'endDate','')::timestamptz,
            feat -> 'status' -> 'type' ->> 'state',
            feat -> 'status' -> 'type' ->> 'shortDetail',
            venue ->> 'fullName',
            venue -> 'address' ->> 'city',
            venue -> 'address' ->> 'state',
            venue -> 'address' ->> 'country',
            feat -> 'circuit' ->> 'fullName',
            feat, now()
          )
          ON CONFLICT (espn_event_id) DO UPDATE SET
            name = EXCLUDED.name, short_name = EXCLUDED.short_name,
            start_date = EXCLUDED.start_date, end_date = EXCLUDED.end_date,
            state = EXCLUDED.state, status_short = EXCLUDED.status_short,
            venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city,
            venue_state = EXCLUDED.venue_state, venue_country = EXCLUDED.venue_country,
            circuit_name = EXCLUDED.circuit_name,
            raw_jsonb = EXCLUDED.raw_jsonb, last_seen_at = now();
          v_upserted := v_upserted + 1;
        END LOOP;
      END IF;
    END IF;
    UPDATE espn_tournament_pending
       SET resolved_at = now(),
           http_status = r.status_code,
           events_count = jsonb_array_length(COALESCE(v_body -> 'events','[]'::jsonb))
     WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_upserted;
END $$;

-- ============================================================================
-- (7) Matcher: link TEvo tournament events to ESPN tournament rows
-- ============================================================================

CREATE OR REPLACE FUNCTION match_tevo_to_espn_tournaments()
RETURNS TABLE(matched int, attempted int) LANGUAGE plpgsql AS $$
DECLARE
  e RECORD; m RECORD;
  v_attempted int := 0; v_matched int := 0;
  v_sport text; v_tour text;
BEGIN
  FOR e IN
    SELECT id, name, occurs_at_local
    FROM events
    WHERE occurs_at_local::timestamptz > now() - interval '1 day'
      AND occurs_at_local::timestamptz < now() + interval '400 days'
      AND classify_tournament_sport(name) IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM event_xref ex WHERE ex.tevo_event_id = events.id)
  LOOP
    v_attempted := v_attempted + 1;
    v_sport := classify_tournament_sport(e.name);
    v_tour  := classify_tennis_tour(e.name);

    SELECT et.* INTO m
    FROM espn_tournament_events et
    WHERE
      (
        (v_sport = 'f1'    AND et.espn_league = 'f1')
        OR (v_sport = 'pga'  AND et.espn_league = 'pga')
        OR (v_sport = 'lpga' AND et.espn_league = 'lpga')
        OR (v_sport = 'liv'  AND et.espn_league = 'liv')
        OR (v_sport = 'tennis' AND et.espn_league IN ('atp','wta')
              AND (v_tour IS NULL OR et.espn_league = v_tour))
      )
      AND e.occurs_at_local::timestamptz BETWEEN et.start_date - interval '1 day'
                                            AND COALESCE(et.end_date, et.start_date + interval '7 days') + interval '1 day'
      AND tournament_match_score(e.name, et.name) >= 1
    ORDER BY
      tournament_match_score(e.name, et.name) DESC,
      abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - et.start_date))) ASC
    LIMIT 1;

    -- IF FOUND avoids the IS NOT NULL trap (RECORD has nullable cols)
    IF FOUND THEN
      INSERT INTO event_xref(tevo_event_id, espn_event_id, espn_league, espn_slug, match_method, meta)
      VALUES (
        e.id, m.espn_event_id, m.espn_league,
        m.espn_sport || '/' || m.espn_league,
        'tournament_token_overlap',
        jsonb_build_object(
          'tevo_name', e.name,
          'espn_name', m.name,
          'token_score', tournament_match_score(e.name, m.name)
        )
      )
      ON CONFLICT DO NOTHING;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_matched, v_attempted;
END $$;

COMMENT ON FUNCTION match_tevo_to_espn_tournaments() IS
  'Links upcoming TEvo F1/tennis/golf/LIV events to ESPN tournament rows '
  'via (sport, date overlap, token-overlap score >= 1). Idempotent — only '
  'matches events without an existing event_xref.';

-- ============================================================================
-- (8) View — joins TEvo tournament events to ESPN tournament context
-- ============================================================================

CREATE OR REPLACE VIEW v_event_tournament_context AS
SELECT
  e.id  AS tevo_event_id,
  e.name AS tevo_event_name,
  e.occurs_at_local,
  ex.espn_event_id,
  et.espn_sport, et.espn_league,
  et.name AS tournament_name,
  et.short_name AS tournament_short_name,
  et.start_date AS tournament_start,
  et.end_date   AS tournament_end,
  et.state, et.status_short,
  et.venue_name AS tournament_venue,
  et.venue_city, et.venue_state, et.venue_country,
  et.circuit_name
FROM events e
JOIN event_xref ex ON ex.tevo_event_id = e.id
                  AND ex.espn_league IN ('f1','atp','wta','pga','lpga','liv')
JOIN espn_tournament_events et ON et.espn_event_id = ex.espn_event_id
WHERE e.occurs_at_local::timestamptz > now() - interval '1 day';

COMMENT ON VIEW v_event_tournament_context IS
  'Per-TEvo-event ESPN tournament context for individual-sport events '
  '(F1 races, tennis tournaments, golf tournaments, LIV golf).';

-- ============================================================================
-- (9) get_event_context() gains 18th key: tournament
--     Populated only for matched F1/tennis/golf/LIV events; other events get
--     {present: false}.
-- ============================================================================

CREATE OR REPLACE FUNCTION get_event_context(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_event jsonb; v_pricing jsonb; v_espn jsonb; v_performer jsonb;
  v_weather jsonb; v_competitors jsonb; v_orders jsonb;
  v_odds jsonb; v_reddit jsonb; v_news jsonb; v_x jsonb; v_rivalry jsonb;
  v_calendar jsonb; v_alerts jsonb; v_injuries jsonb; v_tournament jsonb;
BEGIN
  SELECT to_jsonb(e) - 'performer_ids' INTO v_event FROM events e WHERE id = p_event_id;
  IF v_event IS NULL THEN
    RETURN jsonb_build_object('error','event_not_found','tevo_event_id',p_event_id);
  END IF;
  SELECT to_jsonb(ef) INTO v_pricing FROM v_event_full_v2 ef WHERE ef.tevo_event_id = p_event_id;
  SELECT jsonb_build_object(
    'espn_event_id', x.espn_event_id,
    'latest_state',  (SELECT state FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1),
    'latest_status', (SELECT status_short FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1),
    'latest_score',  (SELECT home_score::text || '-' || away_score::text FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1)
  ) INTO v_espn FROM event_xref x WHERE x.tevo_event_id = p_event_id LIMIT 1;
  SELECT jsonb_build_object(
    'tevo_performer_id', pw.tevo_performer_id, 'wiki_title', pw.wiki_title,
    'wiki_url', pw.wiki_url, 'description', pw.description,
    'extract', pw.extract, 'image_url', pw.image_url
  ) INTO v_performer FROM performer_wikipedia pw
  JOIN events e ON e.primary_performer_id = pw.tevo_performer_id
  WHERE e.id = p_event_id AND NOT pw.is_rejected LIMIT 1;
  SELECT to_jsonb(w) INTO v_weather FROM v_event_weather_with_fallback w WHERE w.tevo_event_id = p_event_id;
  SELECT competitors INTO v_competitors FROM event_competitors_snapshot WHERE tevo_event_id = p_event_id;
  SELECT to_jsonb(o) INTO v_orders FROM our_orders_by_event o WHERE o.tevo_event_id = p_event_id;
  SELECT to_jsonb(bo) INTO v_odds FROM v_event_betting_odds_latest bo WHERE bo.tevo_event_id = p_event_id;
  SELECT to_jsonb(rp) INTO v_reddit FROM v_performer_reddit_pulse rp
    JOIN events e ON e.primary_performer_id = rp.tevo_performer_id WHERE e.id = p_event_id;

  SELECT jsonb_agg(jsonb_build_object(
           'title', vn.title, 'subreddit', vn.subreddit,
           'created_utc', vn.created_utc, 'url', vn.url,
           'matched', vn.keyword_match->'hits',
           'categories', vn.keyword_match->'categories'
         ) ORDER BY vn.created_utc DESC) INTO v_news
  FROM (SELECT * FROM v_reddit_important_recent ORDER BY created_utc DESC LIMIT 10) vn
  JOIN events e ON e.primary_performer_id = vn.tevo_performer_id
  WHERE e.id = p_event_id;

  SELECT jsonb_build_object(
           'team_known', count(*) FILTER (WHERE account_type = 'team_official'),
           'beat_reporters_known', count(*) FILTER (WHERE account_type = 'beat_reporter'),
           'league_known', count(*) FILTER (WHERE account_type = 'league_official'),
           'insiders_total', (SELECT count(*) FROM important_x_accounts WHERE account_type = 'insider')
         ) INTO v_x
  FROM important_x_accounts xa
  JOIN events e ON e.primary_performer_name = xa.team_name WHERE e.id = p_event_id;

  SELECT jsonb_build_object(
           'rivalry_name', re.rivalry_name, 'league', re.league,
           'is_branded', re.is_branded, 'rivalry_intensity', re.rivalry_intensity,
           'wikipedia_url', re.wikipedia_url, 'notes', re.notes
         ) INTO v_rivalry
  FROM v_rivalry_events re
  WHERE re.tevo_event_id = p_event_id LIMIT 1;

  SELECT jsonb_build_object(
           'country', cc.inferred_country, 'state', cc.inferred_state, 'city', cc.inferred_city,
           'is_holiday', cc.is_holiday, 'within_holiday_window', cc.within_holiday_window,
           'school_break_active', cc.school_break_active,
           'holidays_today', COALESCE(cc.holidays_today, '[]'::json),
           'holidays_nearby', COALESCE(cc.holidays_nearby, '[]'::json),
           'school_breaks_active', COALESCE(cc.school_breaks_active, '[]'::json)
         ) INTO v_calendar
  FROM v_event_calendar_context cc
  WHERE cc.tevo_event_id = p_event_id;

  SELECT jsonb_agg(jsonb_build_object(
           'alert_id', wa.alert_id, 'event', wa.event,
           'severity', wa.severity, 'urgency', wa.urgency, 'certainty', wa.certainty,
           'impact_tier', wa.impact_tier,
           'effective_at', wa.effective_at, 'expires_at', wa.expires_at,
           'headline', wa.headline, 'instruction', wa.instruction,
           'sender_name', wa.sender_name,
           'max_wind_gust_mph', wa.max_wind_gust_mph,
           'max_hail_size_in',  wa.max_hail_size_in)
         ORDER BY
           CASE wa.severity WHEN 'Extreme' THEN 0 WHEN 'Severe' THEN 1
             WHEN 'Moderate' THEN 2 WHEN 'Minor' THEN 3 ELSE 4 END) INTO v_alerts
  FROM v_event_active_weather_alerts wa
  WHERE wa.tevo_event_id = p_event_id;

  WITH inj AS (
    SELECT * FROM v_event_injuries WHERE tevo_event_id = p_event_id
  ),
  by_side AS (
    SELECT
      side,
      jsonb_agg(jsonb_build_object(
        'athlete_id', athlete_id, 'name', athlete_name, 'position', position,
        'status', status, 'injury_type', injury_type,
        'return_date', return_date, 'short_comment', short_comment,
        'impact_tier', impact_tier, 'last_seen_at', injury_last_seen_at
      ) ORDER BY
        CASE impact_tier WHEN 'out_long' THEN 0 WHEN 'out_short' THEN 1
          WHEN 'uncertain' THEN 2 ELSE 3 END,
        athlete_name) AS rows,
      max(espn_team_id) AS team_espn_id, count(*) AS total_count
    FROM inj WHERE side IN ('home','away') GROUP BY side
  )
  SELECT jsonb_build_object(
    'home', COALESCE((SELECT jsonb_build_object('team_espn_id', team_espn_id, 'rows', rows, 'total', total_count) FROM by_side WHERE side='home'),
            jsonb_build_object('total', 0, 'rows', '[]'::jsonb)),
    'away', COALESCE((SELECT jsonb_build_object('team_espn_id', team_espn_id, 'rows', rows, 'total', total_count) FROM by_side WHERE side='away'),
            jsonb_build_object('total', 0, 'rows', '[]'::jsonb)),
    'total', (SELECT count(*) FROM inj),
    'as_of', (SELECT max(injury_last_seen_at) FROM inj)
  ) INTO v_injuries;

  SELECT jsonb_build_object(
           'espn_event_id', tc.espn_event_id,
           'sport', tc.espn_sport, 'league', tc.espn_league,
           'tournament_name', tc.tournament_name,
           'tournament_short_name', tc.tournament_short_name,
           'tournament_start', tc.tournament_start,
           'tournament_end', tc.tournament_end,
           'state', tc.state, 'status_short', tc.status_short,
           'tournament_venue', tc.tournament_venue,
           'venue_city', tc.venue_city, 'venue_state', tc.venue_state,
           'venue_country', tc.venue_country, 'circuit_name', tc.circuit_name
         ) INTO v_tournament
  FROM v_event_tournament_context tc
  WHERE tc.tevo_event_id = p_event_id LIMIT 1;

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id, 'event', v_event,
    'pricing', COALESCE(v_pricing, '{}'::jsonb),
    'espn', COALESCE(v_espn, jsonb_build_object('present', false)),
    'odds', COALESCE(v_odds, jsonb_build_object('present', false)),
    'performer', COALESCE(v_performer, jsonb_build_object('present', false)),
    'weather', COALESCE(v_weather, jsonb_build_object('present', false)),
    'weather_alerts', COALESCE(v_alerts, '[]'::jsonb),
    'injuries', COALESCE(v_injuries, jsonb_build_object('present', false)),
    'tournament', COALESCE(v_tournament, jsonb_build_object('present', false)),
    'competitors', COALESCE(v_competitors, '[]'::jsonb),
    'reddit', COALESCE(v_reddit, jsonb_build_object('present', false)),
    'important_news', COALESCE(v_news, '[]'::jsonb),
    'x_accounts_known', COALESCE(v_x, jsonb_build_object('team_known', 0)),
    'rivalry', COALESCE(v_rivalry, jsonb_build_object('present', false)),
    'calendar', COALESCE(v_calendar, jsonb_build_object('present', false)),
    'our_orders', COALESCE(v_orders, jsonb_build_object('present', false)),
    'generated_at', now()
  );
END $$;

COMMENT ON FUNCTION get_event_context(bigint) IS
  'Single-row jsonb summary of every context dimension. Now 18 keys '
  'including tournament (F1/tennis/golf/LIV ESPN tournament context).';

-- ============================================================================
-- (10) Cron schedules — weekly crawl, daily match
-- ============================================================================

SELECT cron.schedule('espn_tournament_queue_weekly',  '0 4 * * 0',     $$ SELECT public.espn_tournament_queue(); $$);
SELECT cron.schedule('espn_tournament_process_5min',  '5-59/5 * * * *',$$ SELECT public.espn_tournament_process(); $$);
SELECT cron.schedule('match_tournaments_daily',       '30 4 * * *',    $$ SELECT public.match_tevo_to_espn_tournaments(); $$);
