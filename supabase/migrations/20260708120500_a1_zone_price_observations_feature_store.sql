-- ============================================================================
-- Migration 20260708120000 — Zone price-attribution feature store (Phase 1)
--
-- Lane:     data plane (A1) — new analytical fact table + point-in-time builder
-- Touches:  zone_price_observations (NEW table),
--           build_zone_price_observations(bigint, date) (NEW fn),
--           build_zone_price_observations_day(date) (NEW fn)
-- Reads:    zone_metrics, events, event_xref, espn_event_snapshots,
--           espn_team_snapshots, espn_player_gamelog, espn_athletes,
--           performer_espn_team_xref, performer_metadata, performer_baselines,
--           performer_metrics_daily, venue_assets, v_event_holidays,
--           event_competitors_snapshot
--
-- Operator directive (2026-07-08): "store as much data in relation to zones …
--   min/max per game per performer per day of week, roster that game had,
--   day of the week, standings of team, everything we collect — idea is to
--   figure out how much each factor weighs, what individual player draws,
--   branding."
--
-- Design: one immutable row per (event_id, zone, capture_date). The zone's
--   pricing (from zone_metrics) is the TARGET; every demand factor is resolved
--   AS-OF the capture_date so the matrix is valid for regression/attribution
--   (March standings + that night's realized roster explain a March price —
--   never end-of-season data leaking backward).
--
-- Phase 1 populates every factor we already collect: standings & form (home +
--   opponent), betting-market signals, realized attendance, schedule context,
--   venue capacity → fill-rate, market-competition, team-brand/draw, and the
--   realized roster (who actually played). Player-brand aggregates (fantasy
--   rank, per-athlete Wikipedia pageviews, stat-derived brand) and social
--   follower counts are created here as NULLABLE columns and back-filled by
--   Phase 2 (the athlete-brand pipeline) — nothing here depends on them.
-- ============================================================================

CREATE TABLE IF NOT EXISTS zone_price_observations (
  observation_id           bigserial PRIMARY KEY,

  -- ---- grain ----
  event_id                 bigint  NOT NULL,
  zone                     text    NOT NULL,
  zone_source              text,
  capture_date             date    NOT NULL,
  captured_at              timestamptz,          -- latest zone_metrics ts that day

  -- ---- event / matchup context ----
  performer_id             bigint,               -- home / primary performer
  performer_name           text,
  venue_id                 bigint,
  venue_capacity           integer,
  venue_is_indoor          boolean,
  opponent_performer_id    bigint,
  opponent_name            text,
  espn_event_id            text,
  espn_league              text,
  home_away                text,                 -- our performer: 'home' / 'away'

  -- ---- schedule factors ----
  event_local_ts           text,                 -- events.occurs_at_local (raw)
  event_date               date,
  event_dow                integer,              -- 0=Sun … 6=Sat
  event_is_weekend         boolean,
  event_start_bucket       text,                 -- matinee/afternoon/evening/night
  days_to_event            integer,              -- event_date - capture_date
  event_month              integer,
  season_year              integer,
  holiday_name             text,
  holiday_attendance_impact text,

  -- ---- price target (from zone_metrics) ----
  tickets_count            integer,
  groups_count             integer,
  sections_count           integer,
  retail_min               numeric,
  retail_p25               numeric,
  retail_median            numeric,
  retail_mean              numeric,
  retail_p75               numeric,
  retail_p90               numeric,
  retail_max               numeric,
  retail_sum               numeric,
  wholesale_min            numeric,
  wholesale_median         numeric,
  wholesale_mean           numeric,
  wholesale_max            numeric,
  getin_price              numeric,
  owned_groups_count       integer,
  owned_tickets_count      integer,
  owned_share              numeric,
  owned_median_retail      numeric,
  fill_rate                numeric,              -- tickets_count / venue_capacity

  -- ---- home team standings & form (as-of capture_date) ----
  home_wins                integer,
  home_losses              integer,
  home_ties                integer,
  home_win_pct             numeric,
  home_games_back          numeric,
  home_playoff_seed        integer,
  home_conf_rank           integer,
  home_div_rank            integer,
  home_streak              text,

  -- ---- opponent standings & form (as-of capture_date) ----
  opp_wins                 integer,
  opp_losses               integer,
  opp_win_pct              numeric,
  opp_games_back           numeric,
  opp_playoff_seed         integer,
  opp_conf_rank            integer,
  opp_div_rank             integer,
  opp_streak               text,

  -- ---- betting-market signals (as-of) + realized attendance ----
  mkt_spread               text,
  mkt_over_under           numeric,
  mkt_home_ml              integer,
  mkt_away_ml              integer,
  mkt_home_win_prob        numeric,
  game_attendance          integer,              -- realized (label, not a live feature)

  -- ---- roster / who actually played (realized) ----
  roster_count             integer,
  roster_athlete_ids       jsonb,
  roster_hash              text,                 -- detects lineup changes
  -- player-brand aggregates — NULL until Phase 2 fills them
  roster_brand_sum         numeric,
  roster_brand_max         numeric,
  roster_brand_top3        numeric,
  roster_fantasy_best_rank integer,
  roster_fantasy_pts_sum   numeric,
  roster_wiki_pv_sum       bigint,
  roster_wiki_pv_max       bigint,
  star_athlete_id          text,
  star_athlete_name        text,

  -- ---- team brand / draw ----
  perf_popularity          numeric,
  perf_long_term_popularity numeric,
  perf_baseline_median_retail numeric,
  perf_daily_price_median  numeric,
  perf_daily_getin_median  numeric,
  perf_daily_tickets       integer,
  perf_category            text,
  perf_genre               text,
  perf_event_type          text,
  perf_brand_color         text,
  perf_has_logo            boolean,
  perf_s4k_boost           numeric,
  team_social_followers    bigint,               -- NULL until a social source is wired
  opp_social_followers     bigint,               -- NULL until a social source is wired

  -- ---- market competition ----
  market_competing_events  integer,

  -- ---- meta ----
  feature_version          integer NOT NULL DEFAULT 1,
  built_at                 timestamptz NOT NULL DEFAULT now(),

  UNIQUE (event_id, zone, capture_date)
);

CREATE INDEX IF NOT EXISTS idx_zpo_event        ON zone_price_observations (event_id);
CREATE INDEX IF NOT EXISTS idx_zpo_capture_date ON zone_price_observations (capture_date);
CREATE INDEX IF NOT EXISTS idx_zpo_performer    ON zone_price_observations (performer_id);
CREATE INDEX IF NOT EXISTS idx_zpo_perf_dow     ON zone_price_observations (performer_id, event_dow);
CREATE INDEX IF NOT EXISTS idx_zpo_zone         ON zone_price_observations (event_id, zone);

COMMENT ON TABLE zone_price_observations IS
  'Zone price-attribution feature store: one row per (event, zone, capture_date). '
  'zone_metrics pricing is the target; all factors resolved as-of capture_date. '
  'Built by build_zone_price_observations(). Player-brand + social columns filled by Phase 2.';

-- ============================================================================
-- Builder: resolve every factor AS-OF p_capture_date for one event, upsert all
-- its zones observed that day. Re-runnable (delete-then-insert per event/day).
-- ============================================================================
CREATE OR REPLACE FUNCTION build_zone_price_observations(
  p_event_id bigint,
  p_capture_date date
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows integer;
  v_day_end timestamptz := (p_capture_date + 1)::timestamptz;   -- exclusive upper bound
BEGIN
  DELETE FROM zone_price_observations
   WHERE event_id = p_event_id AND capture_date = p_capture_date;

  WITH ev AS (
    SELECT e.id, e.primary_performer_id, e.primary_performer_name,
           e.venue_id, e.occurs_at_local, e.event_type,
           e.popularity_score, e.long_term_popularity_score,
           left(e.occurs_at_local, 10)::date AS event_date,
           nullif(substring(e.occurs_at_local, 12, 2), '')::int AS start_hour
      FROM events e
     WHERE e.id = p_event_id
  ),
  -- home team identity (prefer explicit xref, fall back to performer_metadata)
  home_team AS (
    SELECT COALESCE(x.espn_team_id, pm.espn_team_id) AS espn_team_id,
           COALESCE(x.espn_league,  pm.espn_league)  AS espn_league
      FROM ev
      LEFT JOIN performer_espn_team_xref x ON x.tevo_performer_id = ev.primary_performer_id
      LEFT JOIN performer_metadata      pm ON pm.performer_id      = ev.primary_performer_id
     LIMIT 1
  ),
  xref AS (
    SELECT ex.espn_event_id, ex.espn_league
      FROM event_xref ex WHERE ex.tevo_event_id = p_event_id LIMIT 1
  ),
  -- latest ESPN game snapshot as-of capture (market signals); attendance taken
  -- from the most recent snapshot overall (realized label)
  espn_asof AS (
    SELECT s.home_team_id, s.away_team_id, s.spread, s.over_under,
           s.home_ml, s.away_ml, s.home_win_prob
      FROM espn_event_snapshots s, xref
     WHERE s.espn_event_id = xref.espn_event_id
       AND s.captured_at < v_day_end
     ORDER BY s.captured_at DESC LIMIT 1
  ),
  espn_final AS (
    SELECT s.attendance, s.home_team_id, s.away_team_id
      FROM espn_event_snapshots s, xref
     WHERE s.espn_event_id = xref.espn_event_id
     ORDER BY s.captured_at DESC LIMIT 1
  ),
  opp AS (   -- opponent = the espn team that is not the home team
    SELECT CASE WHEN ef.home_team_id = ht.espn_team_id THEN ef.away_team_id
                ELSE ef.home_team_id END AS opp_team_id
      FROM espn_final ef, home_team ht
  ),
  opp_perf AS (
    SELECT px.tevo_performer_id AS performer_id, pm.name AS performer_name
      FROM opp
      LEFT JOIN performer_espn_team_xref px ON px.espn_team_id = opp.opp_team_id
      LEFT JOIN performer_metadata      pm ON pm.performer_id  = px.tevo_performer_id
     LIMIT 1
  ),
  home_stand AS (
    SELECT ts.wins, ts.losses, ts.ties, ts.win_pct, ts.games_back,
           ts.playoff_seed, ts.conference_rank, ts.division_rank, ts.streak
      FROM espn_team_snapshots ts, home_team ht
     WHERE ts.espn_team_id = ht.espn_team_id AND ts.espn_league = ht.espn_league
       AND ts.captured_at < v_day_end
     ORDER BY ts.captured_at DESC LIMIT 1
  ),
  opp_stand AS (
    SELECT ts.wins, ts.losses, ts.win_pct, ts.games_back,
           ts.playoff_seed, ts.conference_rank, ts.division_rank, ts.streak
      FROM espn_team_snapshots ts, opp, home_team ht
     WHERE ts.espn_team_id = opp.opp_team_id AND ts.espn_league = ht.espn_league
       AND ts.captured_at < v_day_end
     ORDER BY ts.captured_at DESC LIMIT 1
  ),
  -- realized roster: athletes on the home team who logged the game
  roster AS (
    SELECT count(DISTINCT g.espn_athlete_id) AS n,
           jsonb_agg(DISTINCT g.espn_athlete_id) AS ids,
           md5(string_agg(DISTINCT g.espn_athlete_id, ',' ORDER BY g.espn_athlete_id)) AS h
      FROM espn_player_gamelog g
      JOIN espn_athletes a ON a.espn_athlete_id = g.espn_athlete_id
     , xref, home_team ht
     WHERE g.espn_event_id = xref.espn_event_id
       AND a.espn_team_id = ht.espn_team_id
  ),
  baseline AS (
    SELECT pb.median_retail
      FROM performer_baselines pb, ev
     WHERE pb.performer_id = ev.primary_performer_id
       AND pb.computed_at < v_day_end
     ORDER BY pb.computed_at DESC LIMIT 1
  ),
  daily AS (
    SELECT pmd.price_median, pmd.getin_median, pmd.evo_tickets_total
      FROM performer_metrics_daily pmd, ev
     WHERE pmd.performer_id = ev.primary_performer_id
       AND pmd.split = 'all' AND pmd.snapshot_date <= p_capture_date
     ORDER BY pmd.snapshot_date DESC LIMIT 1
  ),
  brand AS (
    SELECT pm.popularity_score, pm.category_name, pm.genre, pm.what_event_type,
           pm.color_primary, pm.logo_default_url, pm.s4k_popularity_boost
      FROM performer_metadata pm, ev
     WHERE pm.performer_id = ev.primary_performer_id LIMIT 1
  ),
  cap AS (
    SELECT va.capacity, va.is_indoor
      FROM venue_assets va, ev WHERE va.tevo_venue_id = ev.venue_id LIMIT 1
  ),
  holiday AS (
    SELECT h.holiday_name, h.attendance_impact
      FROM v_event_holidays h WHERE h.tevo_event_id = p_event_id
     ORDER BY h.match_specificity DESC NULLS LAST LIMIT 1
  ),
  compete AS (
    SELECT ecs.competitors_count
      FROM event_competitors_snapshot ecs WHERE ecs.tevo_event_id = p_event_id
     ORDER BY ecs.refreshed_at DESC LIMIT 1
  ),
  -- latest zone_metrics row per zone for this event on capture_date
  zm AS (
    SELECT DISTINCT ON (m.zone)
           m.zone, m.zone_source, m.captured_at,
           m.tickets_count, m.groups_count, m.sections_count,
           m.retail_min, m.retail_p25, m.retail_median, m.retail_mean,
           m.retail_p75, m.retail_p90, m.retail_max, m.retail_sum,
           m.wholesale_min, m.wholesale_median, m.wholesale_mean, m.wholesale_max,
           m.getin_price, m.owned_groups_count, m.owned_tickets_count,
           m.owned_share, m.owned_median_retail
      FROM zone_metrics m
     WHERE m.event_id = p_event_id
       AND m.captured_at >= p_capture_date::timestamptz
       AND m.captured_at < v_day_end
     ORDER BY m.zone, m.captured_at DESC
  )
  INSERT INTO zone_price_observations (
    event_id, zone, zone_source, capture_date, captured_at,
    performer_id, performer_name, venue_id, venue_capacity, venue_is_indoor,
    opponent_performer_id, opponent_name, espn_event_id, espn_league, home_away,
    event_local_ts, event_date, event_dow, event_is_weekend, event_start_bucket,
    days_to_event, event_month, season_year, holiday_name, holiday_attendance_impact,
    tickets_count, groups_count, sections_count,
    retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90,
    retail_max, retail_sum, wholesale_min, wholesale_median, wholesale_mean,
    wholesale_max, getin_price, owned_groups_count, owned_tickets_count,
    owned_share, owned_median_retail, fill_rate,
    home_wins, home_losses, home_ties, home_win_pct, home_games_back,
    home_playoff_seed, home_conf_rank, home_div_rank, home_streak,
    opp_wins, opp_losses, opp_win_pct, opp_games_back,
    opp_playoff_seed, opp_conf_rank, opp_div_rank, opp_streak,
    mkt_spread, mkt_over_under, mkt_home_ml, mkt_away_ml, mkt_home_win_prob,
    game_attendance, roster_count, roster_athlete_ids, roster_hash,
    perf_popularity, perf_long_term_popularity, perf_baseline_median_retail,
    perf_daily_price_median, perf_daily_getin_median, perf_daily_tickets,
    perf_category, perf_genre, perf_event_type, perf_brand_color, perf_has_logo,
    perf_s4k_boost, market_competing_events, feature_version
  )
  SELECT
    p_event_id, zm.zone, zm.zone_source, p_capture_date, zm.captured_at,
    ev.primary_performer_id, ev.primary_performer_name, ev.venue_id,
    cap.capacity, cap.is_indoor,
    opp_perf.performer_id, opp_perf.performer_name,
    xref.espn_event_id, xref.espn_league,
    CASE WHEN espn_final.home_team_id = ht.espn_team_id THEN 'home'
         WHEN espn_final.away_team_id = ht.espn_team_id THEN 'away' END,
    ev.occurs_at_local, ev.event_date,
    extract(dow FROM ev.event_date)::int,
    extract(dow FROM ev.event_date)::int IN (0, 6),
    CASE WHEN ev.start_hour IS NULL THEN NULL
         WHEN ev.start_hour < 15 THEN 'matinee'
         WHEN ev.start_hour < 18 THEN 'afternoon'
         WHEN ev.start_hour < 20 THEN 'evening'
         ELSE 'night' END,
    (ev.event_date - p_capture_date),
    extract(month FROM ev.event_date)::int,
    extract(year FROM ev.event_date)::int,
    holiday.holiday_name, holiday.attendance_impact,
    zm.tickets_count, zm.groups_count, zm.sections_count,
    zm.retail_min, zm.retail_p25, zm.retail_median, zm.retail_mean,
    zm.retail_p75, zm.retail_p90, zm.retail_max, zm.retail_sum,
    zm.wholesale_min, zm.wholesale_median, zm.wholesale_mean, zm.wholesale_max,
    zm.getin_price, zm.owned_groups_count, zm.owned_tickets_count,
    zm.owned_share, zm.owned_median_retail,
    CASE WHEN cap.capacity > 0 THEN round(zm.tickets_count::numeric / cap.capacity, 6) END,
    home_stand.wins, home_stand.losses, home_stand.ties, home_stand.win_pct,
    home_stand.games_back, home_stand.playoff_seed, home_stand.conference_rank,
    home_stand.division_rank, home_stand.streak,
    opp_stand.wins, opp_stand.losses, opp_stand.win_pct, opp_stand.games_back,
    opp_stand.playoff_seed, opp_stand.conference_rank, opp_stand.division_rank,
    opp_stand.streak,
    espn_asof.spread, espn_asof.over_under, espn_asof.home_ml, espn_asof.away_ml,
    espn_asof.home_win_prob, espn_final.attendance,
    roster.n, roster.ids, roster.h,
    brand.popularity_score, ev.long_term_popularity_score, baseline.median_retail,
    daily.price_median, daily.getin_median, daily.evo_tickets_total,
    brand.category_name, brand.genre, brand.what_event_type,
    brand.color_primary, (brand.logo_default_url IS NOT NULL),
    brand.s4k_popularity_boost, compete.competitors_count, 1
  FROM zm
  CROSS JOIN ev
  LEFT JOIN home_team  ht        ON true
  LEFT JOIN xref                 ON true
  LEFT JOIN espn_asof            ON true
  LEFT JOIN espn_final           ON true
  LEFT JOIN opp_perf             ON true
  LEFT JOIN home_stand           ON true
  LEFT JOIN opp_stand            ON true
  LEFT JOIN roster               ON true
  LEFT JOIN baseline             ON true
  LEFT JOIN daily                ON true
  LEFT JOIN brand                ON true
  LEFT JOIN cap                  ON true
  LEFT JOIN holiday              ON true
  LEFT JOIN compete              ON true;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

-- Convenience: build every event that has a zone_metrics snapshot on p_capture_date.
CREATE OR REPLACE FUNCTION build_zone_price_observations_day(p_capture_date date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
  v_total integer := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT event_id
      FROM zone_metrics
     WHERE captured_at >= p_capture_date::timestamptz
       AND captured_at < (p_capture_date + 1)::timestamptz
  LOOP
    v_total := v_total + build_zone_price_observations(r.event_id, p_capture_date);
  END LOOP;
  RETURN v_total;
END;
$$;

GRANT SELECT ON zone_price_observations TO anon, authenticated;
REVOKE ALL ON FUNCTION build_zone_price_observations(bigint, date) FROM public;
REVOKE ALL ON FUNCTION build_zone_price_observations_day(date) FROM public;
