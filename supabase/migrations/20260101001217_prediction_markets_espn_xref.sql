-- ============================================================================
-- Migration 20260703010000 — prediction markets: also map to ESPN ids
--
-- Lane:     A1 data plane (extends the prediction-markets xref from mig 20260702235600)
-- Touches:  prediction_market_xref (W: +espn_team_id, +espn_event_id cols + indexes),
--           pm_match() (W: populate the ESPN ids),
--           get_event_prediction_markets / get_performer_prediction_markets (W: expose them),
--           performer_espn_team_xref + event_xref (R)
-- Pre-reqs: 20260702235600 (prediction_markets pipeline)
--
-- WHY: prediction-market rows already resolve to a team THROUGH
--   espn_teams_canonical (pm_resolve_performer), and matched games map to a
--   tevo_event_id that has an ESPN twin in event_xref — but we only persisted the
--   tevo_* ids. Persisting the ESPN ids too makes the markets first-class against
--   the ESPN data plane: a market can now be joined straight to espn_team_snapshots
--   / espn_event_snapshots / injuries / win-prob without re-deriving the mapping.
--
-- COVERAGE (measured live 2026-07-03, pre-backfill): 124/124 matched teams have an
--   espn_team_id (100% — they came through the ESPN map by construction); 76/80
--   matched game events resolve to an espn_event_id via event_xref (95%). The
--   remaining ~5% of games simply have no ESPN xref row yet → espn_event_id NULL.
--
-- NOTE: prediction_market_xref.league already equals espn_league (both uppercase
--   'MLB'/'NBA'/…), so no separate espn_league column is added — `league` is it.
-- ============================================================================

ALTER TABLE prediction_market_xref
  ADD COLUMN IF NOT EXISTS espn_team_id  text,
  ADD COLUMN IF NOT EXISTS espn_event_id text;

CREATE INDEX IF NOT EXISTS prediction_market_xref_espn_team_idx
  ON prediction_market_xref(espn_team_id) WHERE espn_team_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS prediction_market_xref_espn_event_idx
  ON prediction_market_xref(espn_event_id) WHERE espn_event_id IS NOT NULL;

COMMENT ON COLUMN prediction_market_xref.espn_team_id IS
  'ESPN team id for tevo_performer_id (via performer_espn_team_xref). Always set when matched.';
COMMENT ON COLUMN prediction_market_xref.espn_event_id IS
  'ESPN event id for tevo_event_id (via event_xref). Set for matched game markets that have an ESPN twin (~95%).';

-- ----------------------------------------------------------------------------
-- pm_match() — now also resolves + stores the ESPN ids alongside the tevo ids.
-- (Body identical to mig 20260702235600 except the two lookups + the extra
-- INSERT/UPDATE columns.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pm_match()
RETURNS TABLE(linked_events int, linked_performers int) LANGUAGE plpgsql AS $$
DECLARE
  m           RECORD;
  v_perf      bigint;
  v_event     bigint;
  v_espn_team text;
  v_espn_evt  text;
  v_ev int := 0;
  v_pf int := 0;
BEGIN
  FOR m IN
    SELECT source, market_id, league, market_type, team_token, subtitle, team_name, event_date
    FROM prediction_markets
    WHERE league IS NOT NULL
      AND coalesce(status,'') NOT IN ('closed','settled','inactive')
  LOOP
    v_perf := pm_resolve_performer(m.league, m.team_token, coalesce(m.subtitle, m.team_name));
    IF v_perf IS NULL AND m.team_name IS NOT NULL THEN
      v_perf := pm_resolve_performer(m.league, NULL, m.team_name);
    END IF;

    IF v_perf IS NULL THEN
      DELETE FROM prediction_market_xref x WHERE x.source=m.source AND x.market_id=m.market_id;
      CONTINUE;
    END IF;

    -- ESPN team id for the resolved performer (prefer the same league).
    SELECT pe.espn_team_id INTO v_espn_team
    FROM performer_espn_team_xref pe
    WHERE pe.tevo_performer_id = v_perf
    ORDER BY (pe.espn_league = m.league) DESC
    LIMIT 1;

    v_event := NULL;
    v_espn_evt := NULL;
    IF m.market_type = 'game' AND m.event_date IS NOT NULL THEN
      SELECT e.id INTO v_event
      FROM events e
      WHERE (e.primary_performer_id = v_perf OR v_perf = ANY(e.performer_ids))
        AND left(e.occurs_at_local, 10) = m.event_date::text
      ORDER BY e.popularity_score DESC NULLS LAST
      LIMIT 1;

      IF v_event IS NOT NULL THEN
        SELECT ex.espn_event_id INTO v_espn_evt
        FROM event_xref ex
        WHERE ex.tevo_event_id = v_event
        ORDER BY (ex.espn_league = m.league) DESC NULLS LAST
        LIMIT 1;
      END IF;
    END IF;

    INSERT INTO prediction_market_xref
      (source, market_id, tevo_event_id, tevo_performer_id, espn_team_id, espn_event_id,
       league, link_method, confidence, linked_at)
    VALUES (m.source, m.market_id, v_event, v_perf, v_espn_team, v_espn_evt, m.league,
            CASE WHEN v_event IS NOT NULL THEN m.source||'_game_team_date'
                 ELSE m.source||'_team' END,
            CASE WHEN v_event IS NOT NULL THEN 0.95 ELSE 0.80 END,
            now())
    ON CONFLICT (source, market_id) DO UPDATE SET
      tevo_event_id=EXCLUDED.tevo_event_id, tevo_performer_id=EXCLUDED.tevo_performer_id,
      espn_team_id=EXCLUDED.espn_team_id, espn_event_id=EXCLUDED.espn_event_id,
      league=EXCLUDED.league, link_method=EXCLUDED.link_method,
      confidence=EXCLUDED.confidence, linked_at=now();

    IF v_event IS NOT NULL THEN v_ev := v_ev + 1; ELSE v_pf := v_pf + 1; END IF;
  END LOOP;

  RETURN QUERY SELECT v_ev, v_pf;
END $$;

COMMENT ON FUNCTION pm_match() IS
  'Links every attributable prediction market to a tevo_performer_id + espn_team_id '
  '(team) and, for dated game markets, the tevo_event_id + espn_event_id (team in '
  'event AND date matches events.occurs_at_local). Idempotent — safe to re-run.';

-- ----------------------------------------------------------------------------
-- Read RPCs — surface the ESPN ids so consumers can join ESPN data directly.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_event_prediction_markets(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $func$
DECLARE
  v_perfs bigint[];
  v_espn_event text;
  v_games jsonb;
  v_fut   jsonb;
BEGIN
  SELECT array_remove(array_cat(ARRAY[e.primary_performer_id], e.performer_ids), NULL)
  INTO v_perfs FROM events e WHERE e.id = p_event_id;

  SELECT ex.espn_event_id INTO v_espn_event
  FROM event_xref ex WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.source, g.subtitle), '[]'::jsonb)
  INTO v_games FROM (
    SELECT p.source, p.market_type, p.title, p.question, p.subtitle,
           p.yes_price, p.no_price, p.last_price, p.volume, p.url, p.status,
           x.tevo_performer_id, x.espn_team_id, x.espn_event_id, x.confidence
    FROM prediction_market_xref x
    JOIN prediction_markets p ON p.source=x.source AND p.market_id=x.market_id
    WHERE x.tevo_event_id = p_event_id
      AND coalesce(p.status,'') NOT IN ('closed','settled','inactive')
  ) g;

  SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.yes_price DESC NULLS LAST), '[]'::jsonb)
  INTO v_fut FROM (
    SELECT DISTINCT ON (p.source, p.market_id)
           p.source, p.market_type, p.title, p.question, p.subtitle,
           p.yes_price, p.no_price, p.last_price, p.volume, p.url, p.status,
           x.tevo_performer_id, x.espn_team_id
    FROM prediction_market_xref x
    JOIN prediction_markets p ON p.source=x.source AND p.market_id=x.market_id
    WHERE x.tevo_event_id IS NULL
      AND x.tevo_performer_id = ANY(coalesce(v_perfs, ARRAY[]::bigint[]))
      AND coalesce(p.status,'') NOT IN ('closed','settled','inactive')
      AND p.yes_price IS NOT NULL
  ) f;

  RETURN jsonb_build_object(
    'event_id',      p_event_id,
    'espn_event_id', v_espn_event,
    'generated_at',  to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'game_markets',  coalesce(v_games,'[]'::jsonb),
    'futures',       coalesce(v_fut,'[]'::jsonb));
END $func$;

CREATE OR REPLACE FUNCTION get_performer_prediction_markets(p_performer_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $func$
DECLARE v_rows jsonb; v_espn_team text;
BEGIN
  SELECT pe.espn_team_id INTO v_espn_team
  FROM performer_espn_team_xref pe WHERE pe.tevo_performer_id = p_performer_id LIMIT 1;

  SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.market_type, m.event_date NULLS LAST), '[]'::jsonb)
  INTO v_rows FROM (
    SELECT p.source, p.market_type, p.league, p.title, p.question, p.subtitle,
           p.event_date, p.yes_price, p.no_price, p.last_price, p.volume, p.url, p.status,
           x.espn_team_id, x.espn_event_id
    FROM prediction_market_xref x
    JOIN prediction_markets p ON p.source=x.source AND p.market_id=x.market_id
    WHERE x.tevo_performer_id = p_performer_id
      AND coalesce(p.status,'') NOT IN ('closed','settled','inactive')
  ) m;

  RETURN jsonb_build_object(
    'performer_id', p_performer_id,
    'espn_team_id', v_espn_team,
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'markets',      coalesce(v_rows,'[]'::jsonb));
END $func$;

-- Grants are unchanged from mig 20260702235600 (CREATE OR REPLACE keeps them),
-- but re-assert for clarity / first-apply-from-zero safety.
REVOKE ALL ON FUNCTION get_event_prediction_markets(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_event_prediction_markets(bigint) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION get_performer_prediction_markets(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_performer_prediction_markets(bigint) TO anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- Backfill the new columns on existing rows (idempotent).
-- ----------------------------------------------------------------------------
SELECT public.pm_match();
