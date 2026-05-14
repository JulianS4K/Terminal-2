-- Migration 20260510220000 · level:secondary-sales · lane:canonical · writes:v_team_season_progression,v_team_recent_results,v_team_attendance_trend,v_team_win_prob_trend,v_team_roster_full,v_team_transactions,v_team_schedule_30d · reads:espn_team_snapshots,espn_event_snapshots,espn_athletes,espn_athlete_team_history,performer_espn_team_xref,events,v_event_sporting_rivalries · pre:20260510210000 (Phase 15 core 10 views)
--
-- Phase 15b: 6 sports-only ESPN expansion views + 1 optional schedule view backing
-- the ESPN Team Panel on the performer-view (sports template) per
-- docs/performer-view-wireframe-v5.md §"Phase 15 view plan". All views join
-- through performer_espn_team_xref; filter by tevo_performer_id at query time.


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


-- v_team_recent_results · reads:espn_event_snapshots,performer_espn_team_xref
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
         es.home_win_prob,
         es.attendance,
         (pet.espn_team_id = es.home_team_id) AS is_home
    FROM performer_espn_team_xref pet
    JOIN espn_event_snapshots es
      ON es.espn_league = pet.espn_league
     AND (es.home_team_id = pet.espn_team_id OR es.away_team_id = pet.espn_team_id)
   ORDER BY es.espn_event_id, es.captured_at DESC
)
SELECT tg.*,
       CASE WHEN tg.is_home THEN tg.home_score   ELSE tg.away_score   END AS team_score,
       CASE WHEN tg.is_home THEN tg.away_score   ELSE tg.home_score   END AS opp_score,
       CASE WHEN tg.is_home THEN tg.away_team_id ELSE tg.home_team_id END AS opp_team_id,
       CASE
         WHEN tg.home_score IS NULL OR tg.away_score IS NULL THEN NULL
         WHEN tg.is_home AND tg.home_score > tg.away_score   THEN 'W'
         WHEN tg.is_home AND tg.home_score < tg.away_score   THEN 'L'
         WHEN tg.is_home                                      THEN 'T'
         WHEN tg.home_score < tg.away_score                   THEN 'W'
         WHEN tg.home_score > tg.away_score                   THEN 'L'
         ELSE 'T'
       END                                                            AS result,
       -- spread cover (positive spread = team is the favorite, must win by >= spread)
       CASE
         WHEN tg.spread IS NULL OR tg.home_score IS NULL OR tg.away_score IS NULL THEN NULL
         WHEN tg.is_home THEN (tg.home_score + tg.spread) > tg.away_score
         ELSE                  (tg.away_score - tg.spread) > tg.home_score
       END                                                            AS covered_spread
  FROM team_games tg;
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
