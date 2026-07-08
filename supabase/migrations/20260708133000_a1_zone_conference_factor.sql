-- ============================================================================
-- Migration 20260708133000 — Conference as a feature-store factor
--
-- Lane:     data plane (A1)
-- Touches:  zone_price_observations (add home_conference, opp_conference)
--           build_zone_price_observations() (populate them from espn_teams_canonical)
--           performer_external_ids (stamp meta.espn_conference for NCAAF)
--
-- Companion to 20260708132000 (conference dimension on espn_teams_canonical).
-- Conference is a strong NCAAF draw/pricing factor — an SEC home game commands a
-- different market than a MAC one — so it becomes a first-class column in the
-- attribution matrix, resolved for both the home team and the opponent.
--
-- feature_version bumped 1 -> 2 (rows built after this carry conference).
-- ============================================================================

ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS home_conference text;
ALTER TABLE zone_price_observations ADD COLUMN IF NOT EXISTS opp_conference  text;

COMMENT ON COLUMN zone_price_observations.home_conference IS
  'Home team conference (NCAAF; from espn_teams_canonical). NULL for pro leagues '
  'with a single table. Pairs with home_conf_rank (rank WITHIN this conference).';

-- Stamp conference onto the espn external-id meta for the mapped NCAAF performers
-- (handy for anything reading performer_external_ids without joining canonical).
UPDATE performer_external_ids pei
   SET meta = pei.meta || jsonb_build_object('espn_conference', etc.conference)
  FROM espn_teams_canonical etc
 WHERE pei.source = 'espn' AND pei.league = 'NCAAF'
   AND etc.espn_league = 'NCAAF' AND etc.espn_team_id = pei.external_id
   AND etc.conference IS NOT NULL;

-- ----------------------------------------------------------------------------
-- Rebuild the builder with home_conference / opp_conference.
-- ----------------------------------------------------------------------------
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
  opp AS (
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
  -- conference of the home team + opponent (NCAAF; NULL for single-table leagues)
  home_conf AS (
    SELECT etc.conference AS home_conference
      FROM espn_teams_canonical etc, home_team ht
     WHERE etc.espn_team_id = ht.espn_team_id AND etc.espn_league = ht.espn_league
     LIMIT 1
  ),
  opp_conf AS (
    SELECT etc.conference AS opp_conference
      FROM espn_teams_canonical etc, opp, home_team ht
     WHERE etc.espn_team_id = opp.opp_team_id AND etc.espn_league = ht.espn_league
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
    home_conference, opp_conference,
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
    home_conf.home_conference, opp_conf.opp_conference,
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
    brand.s4k_popularity_boost, compete.competitors_count, 2
  FROM zm
  CROSS JOIN ev
  LEFT JOIN home_team  ht        ON true
  LEFT JOIN xref                 ON true
  LEFT JOIN espn_asof            ON true
  LEFT JOIN espn_final           ON true
  LEFT JOIN opp_perf             ON true
  LEFT JOIN home_conf            ON true
  LEFT JOIN opp_conf             ON true
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
