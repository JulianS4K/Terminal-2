-- ============================================================================
-- Migration 20260708140000 — Athlete fantasy score + brand (Phase 2, part A)
--
-- Lane:     data plane (A1)
-- Touches:  fantasy_points()  (new: stat line -> fantasy points via default ruleset)
--           espn_athlete_brand (new table: per-athlete season fantasy standing)
--           build_espn_athlete_brand() (new: (re)compute the brand table)
--
-- Operator directive: player brand should "include their stats. use fantasy
--   rankings as ranking level." This derives, per athlete, a season fantasy-point
--   total from espn_player_gamelog (the realized stat lines) scored by the sport's
--   default ruleset, then ranks athletes within their league and maps that to a
--   0-100 brand_score. The feature-store builder (part B) aggregates this over
--   each game's realized roster into roster_brand_* / roster_fantasy_* / star_*.
--
-- Refreshable: build_espn_athlete_brand() is a full recompute (idempotent).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) fantasy_points(league, stats_num) -> numeric
--     Applies the sport's default ruleset. Baseball rulesets are split (bat vs
--     pitch) and chosen by presence of the pitch_when key (IP). Non-fantasy
--     leagues (NHL/MLS/soccer — no ruleset) return NULL.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fantasy_points(p_league text, p_stats jsonb)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_sport text;
  v_rules jsonb;
  v_sub   jsonb;
  v_pts   numeric := 0;
  k text; v text;
BEGIN
  IF p_stats IS NULL THEN RETURN NULL; END IF;
  v_sport := CASE p_league
    WHEN 'MLB'  THEN 'baseball'
    WHEN 'NBA'  THEN 'basketball'
    WHEN 'WNBA' THEN 'basketball'
    WHEN 'NFL'  THEN 'football'
    WHEN 'NCAAF' THEN 'football'
    ELSE NULL END;
  IF v_sport IS NULL THEN RETURN NULL; END IF;

  SELECT rules INTO v_rules FROM fantasy_scoring_rulesets
   WHERE sport = v_sport AND is_default LIMIT 1;
  IF v_rules IS NULL THEN RETURN NULL; END IF;

  IF v_rules->>'__mode__' = 'split' THEN
    IF p_stats ? (v_rules->>'pitch_when') THEN v_sub := v_rules->'pitch';
    ELSE v_sub := v_rules->'bat'; END IF;
  ELSE
    v_sub := v_rules;
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(v_sub)
  LOOP
    -- skip control keys and any non-numeric rule value
    CONTINUE WHEN k LIKE '\_\_%' OR v !~ '^-?[0-9]+(\.[0-9]+)?$';
    v_pts := v_pts + coalesce((p_stats->>k)::numeric, 0) * v::numeric;
  END LOOP;
  RETURN round(v_pts, 2);
END $$;

-- ----------------------------------------------------------------------------
-- (2) espn_athlete_brand — per-athlete season fantasy standing
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS espn_athlete_brand (
  espn_athlete_id    text PRIMARY KEY,
  espn_league        text,
  athlete_name       text,
  games              int,
  season_fantasy_pts numeric,
  avg_fantasy_pts    numeric,
  league_rank        int,      -- 1 = best in league by season fantasy pts
  brand_score        numeric,  -- 0..100 percentile within league
  computed_at        timestamptz DEFAULT now()
);
GRANT SELECT ON espn_athlete_brand TO anon;

-- ----------------------------------------------------------------------------
-- (3) build_espn_athlete_brand() — full recompute from gamelog
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION build_espn_athlete_brand()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows integer;
BEGIN
  TRUNCATE espn_athlete_brand;
  INSERT INTO espn_athlete_brand
    (espn_athlete_id, espn_league, athlete_name, games,
     season_fantasy_pts, avg_fantasy_pts, league_rank, brand_score)
  WITH per_game AS (
    SELECT g.espn_athlete_id, g.espn_league,
           max(g.athlete_name) AS athlete_name,
           fantasy_points(g.espn_league, g.stats_num) AS fp
    FROM espn_player_gamelog g
    WHERE g.stats_num IS NOT NULL
    GROUP BY g.espn_athlete_id, g.espn_league, g.espn_event_id
  ),
  agg AS (
    SELECT espn_athlete_id, espn_league, max(athlete_name) AS athlete_name,
           count(*) FILTER (WHERE fp IS NOT NULL) AS games,
           sum(fp) AS season_pts,
           avg(fp) AS avg_pts
    FROM per_game
    GROUP BY espn_athlete_id, espn_league
    HAVING count(*) FILTER (WHERE fp IS NOT NULL) > 0
  )
  SELECT espn_athlete_id, espn_league, athlete_name, games,
         round(season_pts, 2), round(avg_pts, 2),
         rank() OVER (PARTITION BY espn_league ORDER BY season_pts DESC NULLS LAST)::int,
         round((100 * percent_rank() OVER (PARTITION BY espn_league ORDER BY season_pts ASC NULLS FIRST))::numeric, 1)
  FROM agg;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END $$;

SELECT build_espn_athlete_brand();
