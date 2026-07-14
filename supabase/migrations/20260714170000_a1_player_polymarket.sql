-- ============================================================================
-- Migration 20260714170000 — Wire Polymarket into the player market panel
--
-- Lane:     A1 data plane (extend the player-market read RPC)
-- Touches:  get_player_prediction_markets (W: add a `polymarket` array),
--           prediction_markets (R: the team pipeline already collects Polymarket),
--           espn_athletes (R: resolve the athlete name for the filter)
-- Pre-reqs: 20260714120000 (get_player_prediction_markets + Kalshi player markets),
--           20260702235600 (prediction_markets — Polymarket already ingested here)
--
-- WHY: "wire Polymarket." The team-level pipeline ALREADY polls Polymarket
--   (poly_tag 'nba') into prediction_markets — verified live it holds a full
--   "NBA: LeBron James Next Team" market (Cleveland/GSW/Miami) plus props
--   (sign-by-date, former-team, play-with-Bronny, contract size). It just wasn't
--   surfaced on the player page (get_player_prediction_markets returned Kalshi
--   only). This folds the athlete's Polymarket markets into the same RPC by a
--   NAME FILTER over prediction_markets — zero new ingest, same pattern as the
--   ESPN-news / social feeds.
--
-- FALSE-MATCH GUARD: filter league = p_league (NBA) so the MLB-draft "Justin
--   Lebron" markets never match; match the full name OR the distinctive first
--   name (word-bounded) so "LeBron to Sign With Former Team?" (no surname) is
--   still caught.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_player_prediction_markets(p_athlete_id text, p_league text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_email text;
  v_kind  text;
  v_title text;
  v_close timestamptz;
  v_cands jsonb;
  v_name  text;
  v_first text;
  v_poly  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- ---- Kalshi player markets (unchanged) ------------------------------------
  SELECT max(market_kind), max(title), max(close_time)
  INTO v_kind, v_title, v_close
  FROM player_prediction_markets
  WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league
    AND coalesce(status,'') NOT IN ('closed','settled','inactive');

  SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.yes_price DESC NULLS LAST), '[]'::jsonb)
  INTO v_cands FROM (
    SELECT source, dest_team_name, dest_team_token, dest_performer_id,
           yes_price, last_price, volume, url, status
    FROM player_prediction_markets
    WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league
      AND coalesce(status,'') NOT IN ('closed','settled','inactive')
      AND yes_price IS NOT NULL
  ) c;

  -- ---- Polymarket markets mentioning the athlete (name filter over the team
  --      pipeline; NBA-scoped so MLB "Justin Lebron" noise is excluded) --------
  SELECT full_name INTO v_name
  FROM espn_athletes WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league LIMIT 1;
  v_first := (regexp_match(coalesce(v_name,''), '^([A-Za-z]{5,})\s'))[1];

  IF v_name IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(to_jsonb(pm) ORDER BY pm.yes_price DESC NULLS LAST), '[]'::jsonb)
    INTO v_poly FROM (
      SELECT p.title, p.question, p.subtitle,
             p.yes_price, p.url, p.status, p.market_type, p.event_date
      FROM prediction_markets p
      WHERE p.source = 'polymarket'
        AND p.league = p_league
        AND coalesce(p.status,'') NOT IN ('closed','settled','inactive')
        AND p.yes_price IS NOT NULL
        AND ( p.title ILIKE '%'||v_name||'%' OR p.question ILIKE '%'||v_name||'%'
              OR p.subtitle ILIKE '%'||v_name||'%'
              OR (v_first IS NOT NULL
                  AND (p.title ~* ('\m'||v_first||'\M') OR p.question ~* ('\m'||v_first||'\M'))) )
      ORDER BY p.yes_price DESC NULLS LAST
      LIMIT 15
    ) pm;
  ELSE
    v_poly := '[]'::jsonb;
  END IF;

  IF v_kind IS NULL AND jsonb_array_length(coalesce(v_poly,'[]'::jsonb)) = 0 THEN
    RETURN jsonb_build_object('applicable', false);
  END IF;

  RETURN jsonb_build_object(
    'applicable',   true,
    'market_kind',  v_kind,
    'title',        v_title,
    'close_time',   v_close,
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'candidates',   coalesce(v_cands, '[]'::jsonb),
    'polymarket',   coalesce(v_poly, '[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_player_prediction_markets(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_player_prediction_markets(text, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_player_prediction_markets(text, text) IS
  'Player prediction markets for the player page: Kalshi next-team candidates '
  '(player_prediction_markets) + Polymarket markets mentioning the athlete '
  '(name filter over prediction_markets, league-scoped). Email-gated. '
  'Mig 20260714170000 (adds polymarket to mig 20260714120000).';
