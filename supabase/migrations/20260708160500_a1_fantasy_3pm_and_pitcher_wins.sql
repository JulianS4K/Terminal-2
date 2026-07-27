-- Migration 20260708160000 · level:standard · lane:A1 (data plane — fantasy scoring) · writes:fantasy_augment_gamelog_stats (new), fantasy_gamelog_points, fantasy_points, build_espn_athlete_brand, fantasy_scoring_rulesets (2 UPDATE) · reads:espn_player_gamelog · pre:20260708142000 · auth:operator-requested 2026-07-08 ("proceed" — close the two cheap fantasy stat gaps)
-- ============================================================================
-- Fantasy scoring: recover 3-pointers-made (basketball) + pitcher wins (baseball)
--
-- Gap (see the "best stats" investigation): the site-API gamelog reports
-- shooting as "made-attempt" STRINGS ("3PT":"2-4", "FG":"10-19") and the pitcher
-- decision as a string ("Dec":"W(12-3)"), so the numeric scorer skipped them —
-- meaning the common +1/3PM and a pitcher's win scored ZERO. Both stats are
-- already in the data; they were just unparsed.
--
-- Fix (pure scoring-side; no re-ingest — applies to all historical gamelog rows):
--   1. New shared helper fantasy_augment_gamelog_stats() derives numeric keys
--      3PM/FGM/FTM (split from the made-att strings) and W (from the Dec string)
--      and merges them into the stats object.
--   2. Both scorers (fantasy_gamelog_points — the league engine; and
--      fantasy_points — the athlete-brand ranking) run the augmenter first, so
--      they agree. build_espn_athlete_brand() now scores the FULL stats object
--      (was the numeric-only subset, which by construction lacked these keys).
--   3. Rulesets gain the new stats: NBA/WNBA "3PM":1, MLB pitch "W":5.
--
-- Stat NAMES (3PM/FGM/FTM/W) follow ESPN's own vocabulary as catalogued in
-- cwendt94/espn-api (MIT) basketball/baseball STATS_MAP — reference only.
--
-- NOT fixed here (need ESPN's fantasy players endpoint, not this feed):
--   * Saves / Holds — the site-API gamelog Dec field only carries the W/L
--     starter decision; SV/HLD are absent, so they cannot be derived.
--   * NFL pass/rush/rec yardage & TD namespacing — collides upstream of us.
--   * NHL — not collected at all (no gamelog rows / profile / ruleset).
-- ============================================================================

-- ---- (0) shared augmenter ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.fantasy_augment_gamelog_stats(p_stats jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE WHEN p_stats IS NULL THEN NULL ELSE
    p_stats
    -- basketball: "made-att" string -> numeric MADE count (3PM/FGM/FTM).
    || CASE WHEN p_stats->>'3PT' ~ '^[0-9]+-' THEN jsonb_build_object('3PM', split_part(p_stats->>'3PT','-',1)) ELSE '{}'::jsonb END
    || CASE WHEN p_stats->>'FG'  ~ '^[0-9]+-' THEN jsonb_build_object('FGM', split_part(p_stats->>'FG', '-',1)) ELSE '{}'::jsonb END
    || CASE WHEN p_stats->>'FT'  ~ '^[0-9]+-' THEN jsonb_build_object('FTM', split_part(p_stats->>'FT', '-',1)) ELSE '{}'::jsonb END
    -- baseball: pitcher decision "W(12-3)"/"L(0-1)"/"-" -> W=1 on a win only.
    || CASE WHEN p_stats->>'Dec' ~ '^W' THEN jsonb_build_object('W','1') ELSE '{}'::jsonb END
  END;
$function$;
COMMENT ON FUNCTION public.fantasy_augment_gamelog_stats IS
  'Derives numeric fantasy keys from a raw ESPN gamelog stats object: 3PM/FGM/FTM (split from "made-att" shooting strings) and W (from the pitcher Dec string). Shared by fantasy_gamelog_points + fantasy_points so both scorers agree. Saves/holds are NOT derivable — absent from the site-API gamelog.';

-- ---- (1) league engine scorer: augment before scoring -----------------------
-- (split-mode + numeric-guard semantics unchanged; only the stats source is
--  now the augmented object.)
CREATE OR REPLACE FUNCTION public.fantasy_gamelog_points(p_stats jsonb, p_rules jsonb)
 RETURNS numeric LANGUAGE sql IMMUTABLE AS $function$
  WITH aug AS (SELECT public.fantasy_augment_gamelog_stats(p_stats) AS s),
  m AS (
    SELECT CASE
      WHEN p_rules ? '__mode__' AND (p_rules->>'__mode__') = 'split' THEN
        CASE WHEN aug.s ? coalesce(p_rules->>'pitch_when','IP')
             THEN p_rules->'pitch' ELSE p_rules->'bat' END
      ELSE p_rules END AS map
    FROM aug
  )
  SELECT coalesce(sum(
    (m.map->>k)::numeric
    * CASE WHEN (aug.s->>k) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (aug.s->>k)::numeric ELSE 0 END
  ), 0)::numeric
  FROM m CROSS JOIN aug, LATERAL jsonb_object_keys(m.map) k
  WHERE m.map IS NOT NULL AND aug.s ? k;
$function$;
COMMENT ON FUNCTION public.fantasy_gamelog_points IS
  'Fantasy points for one game-log line. Stats are augmented (fantasy_augment_gamelog_stats) then scored by a flat {label:pts} map, or a split {__mode__:split,pitch_when,bat,pitch} map (baseball) selected by line type.';

-- ---- (2) athlete-brand scorer: augment before scoring ------------------------
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
    IF v_stats ? (v_rules->>'pitch_when') THEN v_sub := v_rules->'pitch';
    ELSE v_sub := v_rules->'bat'; END IF;
  ELSE
    v_sub := v_rules;
  END IF;

  FOR k, v IN SELECT key, value FROM jsonb_each_text(v_sub)
  LOOP
    -- skip control keys and any non-numeric rule value
    CONTINUE WHEN k LIKE '\_\_%' OR v !~ '^-?[0-9]+(\.[0-9]+)?$';
    -- Guard the STAT value too. Now that the brand builder feeds the FULL stats
    -- object (not the numeric-only subset), a ruleset key can map to a
    -- non-numeric gamelog value — e.g. NFL LST="-" (no fumble) or FG/XP="0-0"
    -- (made-attempt string) — and a bare ::numeric would throw, aborting the
    -- whole build_espn_athlete_brand() rebuild. Missing key or non-numeric →
    -- contributes 0, matching fantasy_gamelog_points()'s value guard.
    IF v_stats ? k AND (v_stats->>k) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      v_pts := v_pts + (v_stats->>k)::numeric * v::numeric;
    END IF;
  END LOOP;
  RETURN round(v_pts, 2);
END $$;

-- ---- (3) brand builder: score the FULL stats (augmentable), not stats_num ---
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
           fantasy_points(g.espn_league, g.stats) AS fp   -- full stats: 3PM/W now count
    FROM espn_player_gamelog g
    WHERE g.stats IS NOT NULL
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

-- ---- (4) rulesets: add the recovered stats ----------------------------------
-- Basketball (NBA + WNBA share this default): +1 per 3-pointer made.
UPDATE public.fantasy_scoring_rulesets
   SET rules = rules || '{"3PM":1}'::jsonb
 WHERE name = 'NBA Standard Points';

-- Baseball pitching: +5 for a win (bat submap unchanged).
UPDATE public.fantasy_scoring_rulesets
   SET rules = jsonb_set(rules, '{pitch}', (rules->'pitch') || '{"W":5}'::jsonb)
 WHERE name = 'MLB Standard Points';

-- ---- (5) recompute the stored brand table with the new scoring ---------------
SELECT build_espn_athlete_brand();
