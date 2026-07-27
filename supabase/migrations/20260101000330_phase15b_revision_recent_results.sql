-- Migration 20260514120000 · level:secondary-sales · lane:canonical · writes:espn_teams_canonical(+abbreviation),v_team_season_progression,v_team_recent_results,v_team_attendance_trend,v_team_win_prob_trend,v_team_roster_full,v_team_transactions,v_team_schedule_30d · reads:espn_team_snapshots,espn_event_snapshots,espn_athletes,espn_athlete_team_history,performer_espn_team_xref,events,v_event_sporting_rivalries · pre:20260510210000 (Phase 15 core)
--
-- Phase 15b REVISION. Original PR #92 blocked by A1 on real type bug in
-- v_team_recent_results.covered_spread (text + integer mismatch on a
-- column author treated as numeric — `espn_event_snapshots.spread` is
-- text in the form "<TEAM_ABBR> <signed_number>" and mixes points-spreads
-- with moneylines). This revision:
--   1. Adds espn_teams_canonical.abbreviation + manual backfill (no
--      authoritative source in current ingest payload — meta JSONB is
--      empty for the abbreviation paths).
--   2. Re-authors v_team_recent_results to parse the spread text safely,
--      separate points-spreads from moneylines via abs(line) > 30 heuristic,
--      resolve which team the line is FROM via abbreviation lookup, and
--      compute covered_spread only when all three conditions are met.
--   3. Other 6 views unchanged from PR #92 (they passed A1's audit cleanly).
--
-- Heuristic basis (live data 2026-05-14): points-spreads max |line| = 15.5,
-- moneylines min |line| = 110. Gap is wide enough that abs(line) > 30 is
-- safe; tunable upward only if data shifts.


-- ============================================================================
-- Layer 1: espn_teams_canonical + abbreviation column
-- ============================================================================

ALTER TABLE public.espn_teams_canonical
  ADD COLUMN IF NOT EXISTS abbreviation text;

-- Backfill abbreviations from a manual mapping. When ESPN ingest pipeline
-- gets upgraded to capture `team.abbreviation` from the raw API response,
-- this UPDATE becomes redundant but harmless (re-running yields the same
-- result; ingest can override with a follow-up).
UPDATE public.espn_teams_canonical tc
SET abbreviation = m.abbr
FROM (VALUES
  -- MLB (30)
  ('MLB','1','BAL'),('MLB','2','BOS'),('MLB','3','LAA'),('MLB','4','CHW'),
  ('MLB','5','CLE'),('MLB','6','DET'),('MLB','7','KC'), ('MLB','8','MIL'),
  ('MLB','9','MIN'),('MLB','10','NYY'),('MLB','11','ATH'),('MLB','12','SEA'),
  ('MLB','13','TEX'),('MLB','14','TOR'),('MLB','15','ATL'),('MLB','16','CHC'),
  ('MLB','17','CIN'),('MLB','18','HOU'),('MLB','19','LAD'),('MLB','20','WSH'),
  ('MLB','21','NYM'),('MLB','22','PHI'),('MLB','23','PIT'),('MLB','24','STL'),
  ('MLB','25','SD'), ('MLB','26','SF'), ('MLB','27','COL'),('MLB','28','MIA'),
  ('MLB','29','ARI'),('MLB','30','TB'),
  -- NBA (30)
  ('NBA','1','ATL'),('NBA','2','BOS'),('NBA','3','NO'), ('NBA','4','CHI'),
  ('NBA','5','CLE'),('NBA','6','DAL'),('NBA','7','DEN'),('NBA','8','DET'),
  ('NBA','9','GS'), ('NBA','10','HOU'),('NBA','11','IND'),('NBA','12','LAC'),
  ('NBA','13','LAL'),('NBA','14','MIA'),('NBA','15','MIL'),('NBA','16','MIN'),
  ('NBA','17','BKN'),('NBA','18','NY'), ('NBA','19','ORL'),('NBA','20','PHI'),
  ('NBA','21','PHX'),('NBA','22','POR'),('NBA','23','SAC'),('NBA','24','SA'),
  ('NBA','25','OKC'),('NBA','26','UTAH'),('NBA','27','WSH'),('NBA','28','TOR'),
  ('NBA','29','MEM'),('NBA','30','CHA'),
  -- NFL (32)
  ('NFL','1','ATL'), ('NFL','2','BUF'), ('NFL','3','CHI'), ('NFL','4','CIN'),
  ('NFL','5','CLE'), ('NFL','6','DAL'), ('NFL','7','DEN'), ('NFL','8','DET'),
  ('NFL','9','GB'),  ('NFL','10','TEN'),('NFL','11','IND'),('NFL','12','KC'),
  ('NFL','13','LV'), ('NFL','14','LAR'),('NFL','15','MIA'),('NFL','16','MIN'),
  ('NFL','17','NE'), ('NFL','18','NO'), ('NFL','19','NYG'),('NFL','20','NYJ'),
  ('NFL','21','PHI'),('NFL','22','ARI'),('NFL','23','PIT'),('NFL','24','LAC'),
  ('NFL','25','SF'), ('NFL','26','SEA'),('NFL','27','TB'), ('NFL','28','WSH'),
  ('NFL','29','CAR'),('NFL','30','JAX'),('NFL','33','BAL'),('NFL','34','HOU'),
  -- NHL (32)
  ('NHL','1','BOS'), ('NHL','2','BUF'), ('NHL','3','CGY'), ('NHL','4','CHI'),
  ('NHL','5','DET'), ('NHL','6','EDM'), ('NHL','7','CAR'), ('NHL','8','LA'),
  ('NHL','9','DAL'), ('NHL','10','MTL'),('NHL','11','NJ'), ('NHL','12','NYI'),
  ('NHL','13','NYR'),('NHL','14','OTT'),('NHL','15','PHI'),('NHL','16','PIT'),
  ('NHL','17','COL'),('NHL','18','SJ'), ('NHL','19','STL'),('NHL','20','TB'),
  ('NHL','21','TOR'),('NHL','22','VAN'),('NHL','23','WSH'),('NHL','25','ANA'),
  ('NHL','26','FLA'),('NHL','27','NSH'),('NHL','28','WPG'),('NHL','29','CBJ'),
  ('NHL','30','MIN'),('NHL','37','VGK'),('NHL','124292','SEA'),('NHL','129764','UTAH'),
  -- WNBA (15)
  ('WNBA','3','DAL'), ('WNBA','5','IND'), ('WNBA','6','LA'), ('WNBA','8','MIN'),
  ('WNBA','9','NY'),  ('WNBA','11','PHX'),('WNBA','14','SEA'),('WNBA','16','WSH'),
  ('WNBA','17','LV'), ('WNBA','18','CONN'),('WNBA','19','CHI'),('WNBA','20','ATL'),
  ('WNBA','129689','GS'),('WNBA','131935','TOR'),('WNBA','132052','POR')
) AS m(league, team_id, abbr)
WHERE tc.espn_league = m.league AND tc.espn_team_id = m.team_id;


-- ============================================================================
-- Layer 2: views (6 unchanged from PR #92 + 1 revised)
-- ============================================================================


-- v_team_season_progression · reads:espn_team_snapshots,performer_espn_team_xref
DROP VIEW IF EXISTS v_team_season_progression CASCADE;
CREATE VIEW v_team_season_progression AS
SELECT pet.tevo_performer_id,
       ts.espn_team_id,
       ts.espn_league,
       ts.captured_at,
       ts.wins,
       ts.losses,
       ts.ties,
       ts.win_pct,
       ts.games_back,
       ts.playoff_seed,
       ts.conference_rank,
       ts.division_rank,
       ts.record_summary,
       ts.standing_summary,
       ts.streak,
       ts.is_baseline
  FROM espn_team_snapshots ts
  JOIN performer_espn_team_xref pet
    ON pet.espn_team_id = ts.espn_team_id
   AND pet.espn_league   = ts.espn_league;
GRANT SELECT ON v_team_season_progression TO authenticated, anon, service_role;


-- v_team_recent_results · reads:espn_event_snapshots,espn_teams_canonical,performer_espn_team_xref
-- REVISED. Parses text spread column, separates points-spreads from
-- moneylines via abs(line) > 30 heuristic, resolves spread-team via
-- abbreviation lookup, computes covered_spread from the spread side's
-- perspective and maps it to our team via is_home alignment.
DROP VIEW IF EXISTS v_team_recent_results CASCADE;
CREATE VIEW v_team_recent_results AS
WITH team_games AS (
  SELECT DISTINCT ON (es.espn_event_id)
         pet.tevo_performer_id,
         pet.espn_team_id        AS team_id,
         pet.espn_league,
         es.espn_event_id,
         es.captured_at,
         es.state,
         es.status_short,
         es.home_team_id,
         es.away_team_id,
         es.home_score,
         es.away_score,
         es.spread,
         es.over_under,
         es.home_ml,
         es.away_ml,
         es.home_win_prob,
         es.attendance,
         (pet.espn_team_id = es.home_team_id) AS is_home
    FROM performer_espn_team_xref pet
    JOIN espn_event_snapshots es
      ON es.espn_league = pet.espn_league
     AND (es.home_team_id = pet.espn_team_id OR es.away_team_id = pet.espn_team_id)
   ORDER BY es.espn_event_id, es.captured_at DESC
),
parsed AS (
  -- Parse "<ABBR> <signed_number>" into separate fields.
  -- spread_line is numeric for any well-formed row, NULL otherwise.
  -- spread_abbr is the team identifier the line is FROM.
  SELECT tg.*,
    NULLIF(split_part(tg.spread, ' ', 1), '')                      AS spread_abbr,
    CASE
      WHEN tg.spread ~ '^[A-Z]+ -?[0-9]+(\.[0-9]+)?$'
      THEN (regexp_replace(tg.spread, '^[A-Z]+ ', ''))::numeric
      ELSE NULL
    END AS spread_line
    FROM team_games tg
),
resolved AS (
  -- Resolve spread_abbr → espn_team_id via canonical lookup.
  -- LEFT JOIN: abbreviation may be NULL (unbackfilled) or the spread may
  -- carry a truncated/anomalous abbr (e.g. "CONNECTICU", "CLT"). Both
  -- cases collapse to NULL spread_team_id → covered_spread = NULL.
  SELECT p.*,
    tc.espn_team_id AS spread_team_id
    FROM parsed p
    LEFT JOIN espn_teams_canonical tc
      ON tc.abbreviation = p.spread_abbr
     AND tc.espn_league  = p.espn_league
)
SELECT
  r.tevo_performer_id,
  r.team_id,
  r.espn_league,
  r.espn_event_id,
  r.captured_at,
  r.state,
  r.status_short,
  r.home_team_id,
  r.away_team_id,
  r.home_score,
  r.away_score,
  r.spread,
  r.over_under,
  r.home_ml,
  r.away_ml,
  r.home_win_prob,
  r.attendance,
  r.is_home,
  CASE WHEN r.is_home THEN r.home_score   ELSE r.away_score   END AS team_score,
  CASE WHEN r.is_home THEN r.away_score   ELSE r.home_score   END AS opp_score,
  CASE WHEN r.is_home THEN r.away_team_id ELSE r.home_team_id END AS opp_team_id,
  CASE
    WHEN r.home_score IS NULL OR r.away_score IS NULL THEN NULL
    WHEN r.is_home AND r.home_score > r.away_score   THEN 'W'
    WHEN r.is_home AND r.home_score < r.away_score   THEN 'L'
    WHEN r.is_home                                    THEN 'T'
    WHEN r.home_score < r.away_score                 THEN 'W'
    WHEN r.home_score > r.away_score                 THEN 'L'
    ELSE 'T'
  END AS result,
  -- Parsed numeric line (always present when parseable, regardless of kind)
  r.spread_line,
  -- Discriminator so callers can distinguish points vs moneyline rows.
  CASE
    WHEN r.spread_line IS NULL           THEN NULL
    WHEN abs(r.spread_line) > 30          THEN 'moneyline'
    ELSE                                       'points'
  END AS spread_kind,
  -- covered_spread: only computed for true points-spread rows where we
  -- successfully resolved which team the line was FROM and the game is
  -- final. Push (margin == line) cannot occur with current half-point
  -- data; if integer lines ever land in espn_event_snapshots.spread,
  -- pushes will return false from the spread-team's perspective and
  -- true from the opposite side — follow-up enhancement to enum or NULL
  -- if needed.
  CASE
    WHEN r.spread_line IS NULL                THEN NULL
    WHEN abs(r.spread_line) > 30              THEN NULL  -- moneyline → N/A
    WHEN r.spread_team_id IS NULL             THEN NULL  -- abbr lookup failed
    WHEN r.home_score IS NULL                 THEN NULL
    WHEN r.away_score IS NULL                 THEN NULL
    WHEN r.spread_team_id = r.home_team_id THEN
      -- Home is the spread side. Home covers when home_score + line > away_score.
      -- Our team covers iff (we're home AND home covers) OR (we're away AND home didn't).
      CASE
        WHEN (r.home_score + r.spread_line) > r.away_score THEN r.is_home
        ELSE NOT r.is_home
      END
    WHEN r.spread_team_id = r.away_team_id THEN
      -- Away is the spread side.
      CASE
        WHEN (r.away_score + r.spread_line) > r.home_score THEN NOT r.is_home
        ELSE r.is_home
      END
    ELSE NULL  -- spread_team_id matches neither home nor away (data anomaly)
  END AS covered_spread
  FROM resolved r;
GRANT SELECT ON v_team_recent_results TO authenticated, anon, service_role;


-- v_team_attendance_trend · reads:espn_event_snapshots,performer_espn_team_xref
DROP VIEW IF EXISTS v_team_attendance_trend CASCADE;
CREATE VIEW v_team_attendance_trend AS
SELECT DISTINCT ON (es.espn_event_id)
       pet.tevo_performer_id,
       pet.espn_team_id AS team_id,
       pet.espn_league,
       es.espn_event_id,
       es.captured_at,
       es.attendance,
       es.away_team_id   AS opponent_team_id,
       es.state
  FROM performer_espn_team_xref pet
  JOIN espn_event_snapshots es
    ON es.espn_league   = pet.espn_league
   AND es.home_team_id  = pet.espn_team_id
 WHERE es.attendance IS NOT NULL
 ORDER BY es.espn_event_id, es.captured_at DESC;
GRANT SELECT ON v_team_attendance_trend TO authenticated, anon, service_role;


-- v_team_win_prob_trend · reads:espn_event_snapshots,performer_espn_team_xref
DROP VIEW IF EXISTS v_team_win_prob_trend CASCADE;
CREATE VIEW v_team_win_prob_trend AS
SELECT pet.tevo_performer_id,
       pet.espn_team_id      AS team_id,
       pet.espn_league,
       es.espn_event_id,
       es.captured_at,
       es.state,
       es.home_team_id,
       es.away_team_id,
       (pet.espn_team_id = es.home_team_id) AS is_home,
       -- the canonical home_win_prob ESPN publishes is always relative to home.
       -- normalize to "team_win_prob" so callers don't have to flip it.
       CASE
         WHEN es.home_win_prob IS NULL                THEN NULL
         WHEN pet.espn_team_id = es.home_team_id      THEN es.home_win_prob
         ELSE 1.0 - es.home_win_prob
       END                                            AS team_win_prob
  FROM performer_espn_team_xref pet
  JOIN espn_event_snapshots es
    ON es.espn_league   = pet.espn_league
   AND (es.home_team_id = pet.espn_team_id OR es.away_team_id = pet.espn_team_id)
 WHERE es.home_win_prob IS NOT NULL;
GRANT SELECT ON v_team_win_prob_trend TO authenticated, anon, service_role;


-- v_team_roster_full · reads:espn_athletes,performer_espn_team_xref
DROP VIEW IF EXISTS v_team_roster_full CASCADE;
CREATE VIEW v_team_roster_full AS
SELECT pet.tevo_performer_id,
       a.espn_athlete_id,
       a.full_name,
       a.display_name,
       a.short_name,
       a.jersey,
       a.position,
       a.position_abbr,
       a.height_inches,
       a.weight_lbs,
       a.birth_date,
       a.age,
       a.espn_team_id   AS team_id,
       a.espn_league,
       a.status,
       a.experience_years,
       a.headshot_url,
       a.meta,
       a.first_seen_at,
       a.last_seen_at
  FROM performer_espn_team_xref pet
  JOIN espn_athletes a
    ON a.espn_team_id = pet.espn_team_id
   AND a.espn_league  = pet.espn_league;
GRANT SELECT ON v_team_roster_full TO authenticated, anon, service_role;


-- v_team_transactions · reads:espn_athlete_team_history,espn_athletes,performer_espn_team_xref
DROP VIEW IF EXISTS v_team_transactions CASCADE;
CREATE VIEW v_team_transactions AS
SELECT pet.tevo_performer_id,
       h.id                                AS transaction_id,
       h.espn_athlete_id,
       a.full_name                         AS athlete_name,
       a.position_abbr                     AS athlete_position,
       a.jersey                            AS athlete_jersey,
       h.espn_team_id                      AS team_id,
       h.espn_league,
       h.start_date,
       h.end_date,
       h.transaction_type,
       h.prior_team_id,
       h.notes,
       h.detected_at,
       COALESCE(h.start_date, h.detected_at::date) AS occurred_at
  FROM performer_espn_team_xref pet
  JOIN espn_athlete_team_history h
    ON h.espn_team_id = pet.espn_team_id
   AND h.espn_league  = pet.espn_league
  LEFT JOIN espn_athletes a
    ON a.espn_athlete_id = h.espn_athlete_id;
GRANT SELECT ON v_team_transactions TO authenticated, anon, service_role;


-- v_team_schedule_30d · reads:events,performer_espn_team_xref,v_event_sporting_rivalries (optional, schedule helper)
DROP VIEW IF EXISTS v_team_schedule_30d CASCADE;
CREATE VIEW v_team_schedule_30d AS
WITH base AS (
  SELECT e.id                                AS tevo_event_id,
         e.name                              AS event_name,
         e.occurs_at_local::timestamptz      AS occurs_at,
         e.venue_id, e.venue_name, e.venue_location,
         e.primary_performer_id              AS home_performer_id,
         e.primary_performer_name            AS home_performer_name,
         e.event_type
    FROM events e
   WHERE e.event_type = 'game'
     AND e.occurs_at_local IS NOT NULL
     AND e.occurs_at_local::timestamptz BETWEEN now() - INTERVAL '7 days'
                                            AND now() + INTERVAL '30 days'
)
-- home games (primary_performer_id matches our team)
SELECT pet.tevo_performer_id,
       'H'::text                            AS home_or_away,
       b.tevo_event_id,
       b.event_name,
       b.occurs_at,
       b.venue_id, b.venue_name, b.venue_location,
       b.home_performer_id, b.home_performer_name,
       NULL::bigint                         AS opp_performer_id,
       trim(split_part(b.event_name, ' at ', 1)) AS opp_performer_name,
       EXISTS (SELECT 1 FROM v_event_sporting_rivalries r
                WHERE r.tevo_event_id = b.tevo_event_id) AS is_rivalry
  FROM performer_espn_team_xref pet
  JOIN base b ON b.home_performer_id = pet.tevo_performer_id
UNION ALL
-- away games (event's primary_performer is someone else; we infer ours from "X at Y" prefix)
SELECT pet.tevo_performer_id,
       'A'::text                            AS home_or_away,
       b.tevo_event_id,
       b.event_name,
       b.occurs_at,
       b.venue_id, b.venue_name, b.venue_location,
       b.home_performer_id, b.home_performer_name,
       pet.tevo_performer_id                AS opp_performer_id,
       trim(split_part(b.event_name, ' at ', 1)) AS opp_performer_name,
       EXISTS (SELECT 1 FROM v_event_sporting_rivalries r
                WHERE r.tevo_event_id = b.tevo_event_id) AS is_rivalry
  FROM performer_espn_team_xref pet
  JOIN base b
    ON b.event_name ILIKE '% at %'
   AND lower(trim(split_part(b.event_name, ' at ', 1))) =
       lower(coalesce((SELECT primary_performer_name FROM events e2
                        WHERE e2.primary_performer_id = pet.tevo_performer_id
                        LIMIT 1), ''))
   AND b.home_performer_id <> pet.tevo_performer_id;
GRANT SELECT ON v_team_schedule_30d TO authenticated, anon, service_role;
