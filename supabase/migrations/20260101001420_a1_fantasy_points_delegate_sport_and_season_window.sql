-- Migration 20260708180000 · level:standard · lane:A1 (data plane — fantasy scoring) · writes:fantasy_points, build_espn_athlete_brand · reads:espn_player_gamelog,fantasy_scoring_rulesets · pre:20260705180000 · auth:operator-requested 2026-07-08 (fantasy audit follow-ups)
-- ============================================================================
-- Fantasy audit fixes (2/3 of the DB-side items from the post-merge audit):
--
--   #2 / #1c — fantasy_points() resolved the sport via a hardcoded CASE
--     (MLB/NBA/WNBA/NFL/NCAAF) that silently OMITTED NHL, so once the NHL
--     scoring seed (mig 20260705180000) + hockey gamelog data land, NHL
--     athletes would get no athlete-brand score — diverging from the league
--     engine, which routes NHL via _fantasy_sport_for_league('NHL')='hockey'.
--     Fix: delegate to that same canonical mapper. Unknown leagues map to
--     lower(league) which has no default ruleset → RETURN NULL (unchanged).
--     Any future sport added to _fantasy_sport_for_league + a ruleset now works
--     in BOTH scorers automatically — no second place to update.
--
--   #5 — build_espn_athlete_brand() summed EVERY gamelog row (multi-season:
--     e.g. Wembanyama ~5075 over 2024–2026) into a column named
--     season_fantasy_pts. Constrain per_game to a trailing ~1-season window so
--     the name is honest and the brand reflects current form. brand_score is a
--     within-league percentile, so the ranking stays stable; only the absolute
--     season totals shrink to one season.
-- ============================================================================

-- (1) fantasy_points — delegate sport resolution (fixes #2 / #1c)
CREATE OR REPLACE FUNCTION public.fantasy_points(p_league text, p_stats jsonb)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_sport text;
  v_rules jsonb;
  v_sub   jsonb;
  v_stats jsonb;
  v_pts   numeric := 0;
  k text; v text;
BEGIN
  IF p_stats IS NULL THEN RETURN NULL; END IF;
  v_stats := public.fantasy_augment_gamelog_stats(p_stats);
  -- Canonical sport mapping (was a duplicated CASE that omitted NHL). Unknown
  -- leagues → lower(league) → no default ruleset → RETURN NULL below.
  v_sport := public._fantasy_sport_for_league(p_league);
  SELECT rules INTO v_rules FROM public.fantasy_scoring_rulesets
   WHERE sport = v_sport AND is_default LIMIT 1;
  IF v_rules IS NULL THEN RETURN NULL; END IF;

  IF v_rules->>'__mode__' = 'split' THEN
    IF v_stats ? (v_rules->>'pitch_when') THEN v_sub := v_rules->'pitch';
    ELSE v_sub := v_rules->'bat'; END IF;
  ELSE
    v_sub := v_rules;
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(v_sub)
  LOOP
    -- skip control keys / non-numeric rule value; guard the stat value too
    -- (full-stats object holds non-numeric strings for some keys — see #838).
    CONTINUE WHEN k LIKE '\_\_%' OR v !~ '^-?[0-9]+(\.[0-9]+)?$';
    IF v_stats ? k AND (v_stats->>k) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      v_pts := v_pts + (v_stats->>k)::numeric * v::numeric;
    END IF;
  END LOOP;
  RETURN round(v_pts, 2);
END $$;

-- (2) build_espn_athlete_brand — trailing ~1-season window (fixes #5)
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
           fantasy_points(g.espn_league, g.stats) AS fp
    FROM espn_player_gamelog g
    WHERE g.stats IS NOT NULL
      -- season_fantasy_pts should mean the CURRENT season, not all gamelog
      -- history. A ~1-season trailing window covers the latest season of any
      -- sport and also drops the worker's dateless staleness-marker rows.
      AND g.game_date >= (now() - interval '300 days')
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

-- Recompute with the delegated scorer + season window.
SELECT build_espn_athlete_brand();
