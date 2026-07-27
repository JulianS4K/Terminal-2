-- ============================================================================
-- Migration 20260702235600 — Prediction markets (Kalshi + Polymarket) → events
--
-- Lane:     A1 data plane (cross-source ingest + xref — same family as espn/aq)
-- Touches:  prediction_market_config (W: poll catalog),
--           prediction_markets (W: normalized market rows),
--           prediction_market_pending (W: pg_net queue),
--           prediction_market_xref (W: market → tevo_event_id / tevo_performer_id),
--           pm_resolve_performer / pm_queue / pm_process / pm_match / pm_sweep (W),
--           get_event_prediction_markets / get_performer_prediction_markets (W: RPCs),
--           v_prediction_markets_health (W: view),
--           espn_teams_canonical + performer_espn_team_xref + events (R: matching)
-- Pre-reqs: espn_teams_canonical + performer_espn_team_xref (team identity),
--           events (tevo_event_id keyed), trg_set_updated_at (20260512100000),
--           external: api.elections.kalshi.com + gamma-api.polymarket.com (pg_net)
--
-- WHY: operator asked to wire Kalshi/Polymarket "into events where possible".
--   Both publish live, PUBLIC prediction-market prices (implied probabilities).
--   For a broker terminal these are a demand/attention signal on the very teams &
--   games we sell tickets for. Read-only (RULE-2 spirit — GET-only, never an order
--   POST). Pure pg_net ingest (no *_client.py), matching the FRED/ESPN/reddit
--   precedent (external read sources have no Python client).
--
-- MATCHING (all four paths VERIFIED LIVE 2026-07-02 via pg_net probes on prod):
--   * Kalshi GAME markets (series KX<LG>GAME): event_ticker encodes the date
--     (`KXMLBGAME-26JUL051530DETTEX` → 2026-07-05) and each of the 2 per-game
--     markets carries the team in its ticker suffix (`-DET`) + `yes_sub_title`
--     city ("Detroit") + `yes_ask_dollars` implied win prob. Resolve the team →
--     tevo_performer_id, then find OUR event by (performer ∈ event) AND
--     (game date = left(events.occurs_at_local,10)). Probe: DET/TEX/TB/HOU/MIL/AZ
--     on 2026-07-05 all resolved AND matched real events (3201000
--     "Detroit Tigers at Texas Rangers", 3227808, 3092741).
--   * Polymarket FUTURES ("Will the Boston Red Sox win the 2026 World Series?"):
--     full team name in `question` → espn display_name exact match → performer.
--     Probe: 8/8 World-Series markets resolved (Yankees 15533 … Twins 15540).
--   * Team-name resolver handles the Kalshi↔ESPN abbreviation gaps (e.g. Kalshi
--     "AZ" vs ESPN "ARI") via the `yes_sub_title` city substring fallback —
--     AZ→Arizona Diamondbacks resolved in the live probe.
--   * Polymarket GAME markets (gameStartTime present) reuse the futures resolver
--     on the extracted team + the gameStartTime date for the event join.
--
-- DATA IS PUBLIC → the read RPCs are SECDEF (to read past deny-all RLS) but NOT
--   email-gated (unlike get_macro_series): a broker route calls them with the
--   service_role client, and the prices are public anyway. Grants: anon +
--   authenticated + service_role.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Poll catalog — declarative list of what to pull (tunable without code).
--     poll_kind drives the parser + URL in pm_queue().
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prediction_market_config (
  id           bigserial PRIMARY KEY,
  source       text NOT NULL,               -- 'kalshi' | 'polymarket'
  poll_kind    text NOT NULL,               -- 'kalshi_game' | 'poly_tag'
  league       text NOT NULL,               -- MLB/NBA/NFL/NHL/... (uppercase, matches espn_league)
  api_param    text NOT NULL,               -- kalshi series_ticker | polymarket tag_slug
  enabled      boolean NOT NULL DEFAULT true,
  last_polled_at timestamptz,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, poll_kind, api_param)
);

INSERT INTO prediction_market_config (source, poll_kind, league, api_param, notes) VALUES
  ('kalshi',     'kalshi_game', 'MLB', 'KXMLBGAME', 'MLB moneyline per-game (in season now — verified live)'),
  ('kalshi',     'kalshi_game', 'NBA', 'KXNBAGAME', 'NBA moneyline per-game (empty off-season)'),
  ('kalshi',     'kalshi_game', 'NFL', 'KXNFLGAME', 'NFL moneyline per-game (empty off-season)'),
  ('kalshi',     'kalshi_game', 'NHL', 'KXNHLGAME', 'NHL moneyline per-game (empty off-season)'),
  ('polymarket', 'poly_tag',    'MLB', 'mlb', 'MLB futures + games'),
  ('polymarket', 'poly_tag',    'NBA', 'nba', 'NBA futures + games'),
  ('polymarket', 'poly_tag',    'NFL', 'nfl', 'NFL futures + games'),
  ('polymarket', 'poly_tag',    'NHL', 'nhl', 'NHL futures + games')
ON CONFLICT (source, poll_kind, api_param) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) Normalized market storage. PK (source, market_id). Prices are 0..1
--     (implied probability). RLS deny-all; read via the SECDEF RPCs.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prediction_markets (
  source       text NOT NULL,               -- 'kalshi' | 'polymarket'
  market_id    text NOT NULL,               -- kalshi market ticker | polymarket market id
  group_id     text,                        -- kalshi event_ticker | polymarket event id (the grouping)
  league       text,
  market_type  text,                        -- 'game' | 'futures'
  title        text,                        -- group/event title ("Detroit vs Texas")
  question     text,                        -- specific market question
  subtitle     text,                        -- kalshi yes_sub_title (team/city) | poly outcome
  team_token   text,                        -- kalshi abbrev from ticker suffix (matching aid)
  team_name    text,                        -- resolved team text (poly futures / kalshi city)
  event_date   date,                        -- game date (game markets) — for the event join
  close_time   timestamptz,
  yes_price    numeric,                     -- implied prob of Yes (0..1)
  no_price     numeric,
  last_price   numeric,
  volume       numeric,
  url          text,
  status       text,
  raw          jsonb,
  first_seen   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, market_id)
);
CREATE INDEX IF NOT EXISTS prediction_markets_league_idx ON prediction_markets(league, market_type);
CREATE INDEX IF NOT EXISTS prediction_markets_event_date_idx ON prediction_markets(event_date) WHERE event_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS prediction_markets_updated_idx ON prediction_markets(updated_at DESC);

COMMENT ON TABLE prediction_markets IS
  'Normalized Kalshi + Polymarket prediction-market rows (public prices, implied '
  'probability 0..1). Populated by pm_process() from pg_net. Linked to our '
  'events/performers via prediction_market_xref. Read via get_event_prediction_markets.';

DROP TRIGGER IF EXISTS prediction_markets_updated_at ON prediction_markets;
CREATE TRIGGER prediction_markets_updated_at
  BEFORE UPDATE ON prediction_markets
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ----------------------------------------------------------------------------
-- (3) Match xref — one row per market → our event and/or performer.
--     A game market carries BOTH tevo_event_id (the matched game) and
--     tevo_performer_id (the team it is about); a futures market carries only
--     tevo_performer_id.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prediction_market_xref (
  source            text NOT NULL,
  market_id         text NOT NULL,
  tevo_event_id     bigint,
  tevo_performer_id bigint,
  league            text,
  link_method       text,
  confidence        numeric,
  linked_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, market_id)
);
CREATE INDEX IF NOT EXISTS prediction_market_xref_event_idx ON prediction_market_xref(tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS prediction_market_xref_perf_idx  ON prediction_market_xref(tevo_performer_id) WHERE tevo_performer_id IS NOT NULL;

COMMENT ON TABLE prediction_market_xref IS
  'Links a prediction_markets row to our tevo_event_id (game markets) and/or '
  'tevo_performer_id (team/futures markets). Populated by pm_match().';

-- ----------------------------------------------------------------------------
-- (4) pg_net queue-tracking.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prediction_market_pending (
  id            bigserial PRIMARY KEY,
  source        text NOT NULL,
  poll_kind     text NOT NULL,
  league        text,
  request_id    bigint NOT NULL,
  fired_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  http_status   int,
  rows_upserted int,
  error         text
);
CREATE INDEX IF NOT EXISTS prediction_market_pending_unresolved_idx
  ON prediction_market_pending(fired_at) WHERE resolved_at IS NULL;

-- RLS: deny-all (service_role bypasses; SECDEF RPCs are the read path).
ALTER TABLE prediction_market_config  ENABLE ROW LEVEL SECURITY;
ALTER TABLE prediction_markets        ENABLE ROW LEVEL SECURITY;
ALTER TABLE prediction_market_xref    ENABLE ROW LEVEL SECURITY;
ALTER TABLE prediction_market_pending ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- (5) Team-name resolver → tevo_performer_id.
--     Strategy order (most→least confident): explicit alias map for known
--     Kalshi↔ESPN abbrev gaps, then abbreviation exact, then display_name exact,
--     then a UNIQUE display_name substring (never guesses when >1 team matches,
--     so "New York" can't collide Yankees vs Mets).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pm_resolve_performer(
  p_league text,
  p_abbrev text,
  p_name   text
)
RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_lg   text := upper(coalesce(p_league, ''));
  v_ab   text := nullif(upper(coalesce(p_abbrev, '')), '');
  v_nm   text := nullif(btrim(coalesce(p_name, '')), '');
  v_perf bigint;
  v_team text;
BEGIN
  -- Known Kalshi→ESPN abbreviation aliases (extend as new leagues appear).
  v_ab := CASE v_ab
            WHEN 'AZ'  THEN 'ARI'   -- Arizona (MLB/NHL)
            WHEN 'SFG' THEN 'SF'
            WHEN 'TBR' THEN 'TB'    -- Rays
            WHEN 'TBL' THEN 'TB'    -- Lightning
            WHEN 'WSH' THEN 'WAS'
            WHEN 'WSN' THEN 'WAS'
            WHEN 'CHW' THEN 'CHW'
            WHEN 'KCR' THEN 'KC'
            WHEN 'SDP' THEN 'SD'
            ELSE v_ab
          END;

  -- (a) abbreviation exact
  IF v_ab IS NOT NULL THEN
    SELECT x.tevo_performer_id INTO v_perf
    FROM espn_teams_canonical c
    JOIN performer_espn_team_xref x
      ON x.espn_team_id = c.espn_team_id AND x.espn_league = c.espn_league
    WHERE c.espn_league = v_lg AND upper(c.abbreviation) = v_ab
    LIMIT 1;
    IF v_perf IS NOT NULL THEN RETURN v_perf; END IF;
  END IF;

  -- (b) display_name exact (Polymarket full names)
  IF v_nm IS NOT NULL THEN
    SELECT x.tevo_performer_id INTO v_perf
    FROM espn_teams_canonical c
    JOIN performer_espn_team_xref x
      ON x.espn_team_id = c.espn_team_id AND x.espn_league = c.espn_league
    WHERE c.espn_league = v_lg AND lower(c.display_name) = lower(v_nm)
    LIMIT 1;
    IF v_perf IS NOT NULL THEN RETURN v_perf; END IF;

    -- (c) UNIQUE display_name substring (Kalshi city like "Tampa Bay").
    --     Only when exactly one team in the league matches → never ambiguous.
    SELECT count(*), min(c.display_name) INTO STRICT v_perf, v_team
    FROM espn_teams_canonical c
    WHERE c.espn_league = v_lg AND c.display_name ILIKE '%'||v_nm||'%';
    IF v_perf = 1 THEN
      SELECT x.tevo_performer_id INTO v_perf
      FROM espn_teams_canonical c
      JOIN performer_espn_team_xref x
        ON x.espn_team_id = c.espn_team_id AND x.espn_league = c.espn_league
      WHERE c.espn_league = v_lg AND c.display_name = v_team
      LIMIT 1;
      RETURN v_perf;
    END IF;
  END IF;

  RETURN NULL;
END $$;

COMMENT ON FUNCTION pm_resolve_performer(text, text, text) IS
  'Resolve a prediction-market team (league + abbrev + name/city) to a '
  'tevo_performer_id via espn_teams_canonical + performer_espn_team_xref. '
  'Alias map → abbrev → display_name exact → UNIQUE substring. NULL if unresolved '
  'or ambiguous.';

-- ----------------------------------------------------------------------------
-- (6) Queue — fire one GET per enabled config row. Small pg_sleep between fires
--     (be polite; both APIs are generous). Kalshi = nested markets; Polymarket
--     = one page per tag.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pm_queue()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  cfg   RECORD;
  v_req bigint;
  v_url text;
  v_n   int := 0;
BEGIN
  FOR cfg IN SELECT * FROM prediction_market_config WHERE enabled LOOP
    IF cfg.poll_kind = 'kalshi_game' THEN
      v_url := 'https://api.elections.kalshi.com/trade-api/v2/events'
            || '?limit=200&with_nested_markets=true&status=open&series_ticker='
            || cfg.api_param;
    ELSIF cfg.poll_kind = 'poly_tag' THEN
      v_url := 'https://gamma-api.polymarket.com/events'
            || '?limit=100&closed=false&order=volume24hr&ascending=false&tag_slug='
            || cfg.api_param;
    ELSE
      CONTINUE;
    END IF;

    SELECT net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'Accept', 'application/json',
        'User-Agent', 'Terminal2-S4K/1.0 (+julian@s4kent.com)'),
      timeout_milliseconds := 20000
    ) INTO v_req;

    INSERT INTO prediction_market_pending(source, poll_kind, league, request_id)
    VALUES (cfg.source, cfg.poll_kind, cfg.league, v_req);

    UPDATE prediction_market_config SET last_polled_at = now() WHERE id = cfg.id;
    v_n := v_n + 1;
    PERFORM pg_sleep(0.3);
  END LOOP;
  RETURN v_n;
END $$;

COMMENT ON FUNCTION pm_queue() IS
  'Fires one pg_net GET per enabled prediction_market_config row (Kalshi game '
  'series + Polymarket league tags). Read-only (GET). Drains via pm_process().';

-- ----------------------------------------------------------------------------
-- (7) Process — parse the async responses into prediction_markets.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pm_process()
RETURNS TABLE(processed int, rows_upserted int) LANGUAGE plpgsql AS $$
DECLARE
  r        RECORD;
  v_body   jsonb;
  v_ins    int;
  v_total  int := 0;
  v_proc   int := 0;
  ev       jsonb;
  mk       jsonb;
  v_date   date;
  v_slug   text;
  v_gt     timestamptz;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.source, p.poll_kind, p.league, h.content, h.status_code
    FROM prediction_market_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_proc := v_proc + 1;
    v_ins := 0;

    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;

      -- ---- Kalshi game series ----
      IF v_body IS NOT NULL AND r.poll_kind = 'kalshi_game' THEN
        FOR ev IN SELECT jsonb_array_elements(coalesce(v_body->'events', '[]'::jsonb)) LOOP
          -- date from event_ticker prefix: KX<LG>GAME-YYMONDD....
          v_date := NULL;
          BEGIN
            v_date := to_date((regexp_match(ev->>'event_ticker',
                        '^KX[A-Z]+GAME-(\d{2}[A-Z]{3}\d{2})'))[1], 'YYMONDD');
          EXCEPTION WHEN OTHERS THEN v_date := NULL; END;

          FOR mk IN SELECT jsonb_array_elements(coalesce(ev->'markets', '[]'::jsonb)) LOOP
            INSERT INTO prediction_markets (
              source, market_id, group_id, league, market_type, title, question,
              subtitle, team_token, team_name, event_date, close_time,
              yes_price, no_price, last_price, volume, url, status, raw)
            VALUES (
              'kalshi', mk->>'ticker', ev->>'event_ticker', r.league, 'game',
              ev->>'title', mk->>'title', mk->>'yes_sub_title',
              upper(split_part(mk->>'ticker', '-',
                    array_length(string_to_array(mk->>'ticker','-'),1))),
              mk->>'yes_sub_title', v_date,
              nullif(mk->>'close_time','')::timestamptz,
              nullif(mk->>'yes_ask_dollars','')::numeric,
              nullif(mk->>'no_ask_dollars','')::numeric,
              nullif(mk->>'last_price_dollars','')::numeric,
              nullif(mk->>'volume_fp','')::numeric,
              'https://kalshi.com/markets/'||lower(coalesce(ev->>'series_ticker',''))
                ||'/'||coalesce(ev->>'event_ticker',''),
              mk->>'status',
              jsonb_build_object('yes_bid', mk->>'yes_bid_dollars',
                                 'open_interest', mk->>'open_interest_fp',
                                 'volume_24h', mk->>'volume_24h_fp'))
            ON CONFLICT (source, market_id) DO UPDATE SET
              group_id=EXCLUDED.group_id, league=EXCLUDED.league,
              market_type=EXCLUDED.market_type, title=EXCLUDED.title,
              question=EXCLUDED.question, subtitle=EXCLUDED.subtitle,
              team_token=EXCLUDED.team_token, team_name=EXCLUDED.team_name,
              event_date=EXCLUDED.event_date, close_time=EXCLUDED.close_time,
              yes_price=EXCLUDED.yes_price, no_price=EXCLUDED.no_price,
              last_price=EXCLUDED.last_price, volume=EXCLUDED.volume,
              url=EXCLUDED.url, status=EXCLUDED.status, raw=EXCLUDED.raw,
              updated_at=now();
            v_ins := v_ins + 1;
          END LOOP;
        END LOOP;

      -- ---- Polymarket tag (top-level array of events) ----
      ELSIF v_body IS NOT NULL AND r.poll_kind = 'poly_tag' THEN
        FOR ev IN SELECT jsonb_array_elements(
                    CASE jsonb_typeof(v_body) WHEN 'array' THEN v_body ELSE '[]'::jsonb END) LOOP
          v_slug := ev->>'slug';
          FOR mk IN SELECT jsonb_array_elements(coalesce(ev->'markets', '[]'::jsonb)) LOOP
            v_gt := nullif(mk->>'gameStartTime','')::timestamptz;
            INSERT INTO prediction_markets (
              source, market_id, group_id, league, market_type, title, question,
              subtitle, team_token, team_name, event_date, close_time,
              yes_price, no_price, last_price, volume, url, status, raw)
            VALUES (
              'polymarket', mk->>'id', ev->>'id', r.league,
              CASE WHEN v_gt IS NOT NULL THEN 'game' ELSE 'futures' END,
              ev->>'title', mk->>'question', mk->>'groupItemTitle',
              NULL,
              -- team name: "Will (the) <team> win ..." else the group item title
              coalesce((regexp_match(coalesce(mk->>'question',''),
                        '^Will (?:the )?(.+?) (?:win|beat|make|reach) '))[1],
                       nullif(mk->>'groupItemTitle','')),
              coalesce(v_gt::date, nullif(mk->>'endDateIso','')::date),
              coalesce(v_gt, nullif(mk->>'endDate','')::timestamptz),
              (nullif(mk->>'outcomePrices','')::jsonb->>0)::numeric,
              (nullif(mk->>'outcomePrices','')::jsonb->>1)::numeric,
              nullif(mk->>'lastTradePrice','')::numeric,
              nullif(mk->>'volume24hr','')::numeric,
              'https://polymarket.com/event/'||coalesce(v_slug, ev->>'slug',''),
              CASE WHEN (mk->>'closed')::boolean THEN 'closed'
                   WHEN (mk->>'active')::boolean THEN 'active' ELSE 'inactive' END,
              jsonb_build_object('bestBid', mk->>'bestBid', 'bestAsk', mk->>'bestAsk',
                                 'conditionId', mk->>'conditionId',
                                 'outcomes', mk->>'outcomes'))
            ON CONFLICT (source, market_id) DO UPDATE SET
              group_id=EXCLUDED.group_id, league=EXCLUDED.league,
              market_type=EXCLUDED.market_type, title=EXCLUDED.title,
              question=EXCLUDED.question, subtitle=EXCLUDED.subtitle,
              team_name=EXCLUDED.team_name, event_date=EXCLUDED.event_date,
              close_time=EXCLUDED.close_time, yes_price=EXCLUDED.yes_price,
              no_price=EXCLUDED.no_price, last_price=EXCLUDED.last_price,
              volume=EXCLUDED.volume, url=EXCLUDED.url, status=EXCLUDED.status,
              raw=EXCLUDED.raw, updated_at=now();
            v_ins := v_ins + 1;
          END LOOP;
        END LOOP;
      END IF;
    END IF;

    UPDATE prediction_market_pending
       SET resolved_at = now(), http_status = r.status_code, rows_upserted = v_ins,
           error = CASE WHEN r.status_code <> 200 THEN 'http '||coalesce(r.status_code,0) ELSE NULL END
     WHERE id = r.pending_id;

    v_total := v_total + v_ins;
  END LOOP;

  RETURN QUERY SELECT v_proc, v_total;
END $$;

COMMENT ON FUNCTION pm_process() IS
  'Drains prediction_market_pending → prediction_markets. Parses Kalshi nested '
  'game events (date from event_ticker, team from ticker suffix) and Polymarket '
  'tag pages (team from question, price from outcomePrices).';

-- ----------------------------------------------------------------------------
-- (8) Match — link markets to our events (game) + performers (team/futures).
--     Re-runs are cheap: it (re)computes xref for every market with a resolvable
--     team, so late-arriving events/performers get picked up.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pm_match()
RETURNS TABLE(linked_events int, linked_performers int) LANGUAGE plpgsql AS $$
DECLARE
  m       RECORD;
  v_perf  bigint;
  v_event bigint;
  v_ev    int := 0;
  v_pf    int := 0;
BEGIN
  FOR m IN
    SELECT source, market_id, league, market_type, team_token, subtitle, team_name, event_date
    FROM prediction_markets
    WHERE league IS NOT NULL
      AND coalesce(status,'') NOT IN ('closed','settled','inactive')
  LOOP
    -- Kalshi carries abbrev (team_token) + city (subtitle); Polymarket carries name.
    v_perf := pm_resolve_performer(
                m.league,
                m.team_token,
                coalesce(m.subtitle, m.team_name));
    IF v_perf IS NULL AND m.team_name IS NOT NULL THEN
      v_perf := pm_resolve_performer(m.league, NULL, m.team_name);
    END IF;

    IF v_perf IS NULL THEN
      -- can't attribute → drop any stale xref, skip.
      DELETE FROM prediction_market_xref x WHERE x.source=m.source AND x.market_id=m.market_id;
      CONTINUE;
    END IF;

    v_event := NULL;
    IF m.market_type = 'game' AND m.event_date IS NOT NULL THEN
      SELECT e.id INTO v_event
      FROM events e
      WHERE (e.primary_performer_id = v_perf OR v_perf = ANY(e.performer_ids))
        AND left(e.occurs_at_local, 10) = m.event_date::text
      ORDER BY e.popularity_score DESC NULLS LAST
      LIMIT 1;
    END IF;

    INSERT INTO prediction_market_xref
      (source, market_id, tevo_event_id, tevo_performer_id, league, link_method, confidence, linked_at)
    VALUES (m.source, m.market_id, v_event, v_perf, m.league,
            CASE WHEN v_event IS NOT NULL THEN m.source||'_game_team_date'
                 ELSE m.source||'_team' END,
            CASE WHEN v_event IS NOT NULL THEN 0.95 ELSE 0.80 END,
            now())
    ON CONFLICT (source, market_id) DO UPDATE SET
      tevo_event_id=EXCLUDED.tevo_event_id, tevo_performer_id=EXCLUDED.tevo_performer_id,
      league=EXCLUDED.league, link_method=EXCLUDED.link_method,
      confidence=EXCLUDED.confidence, linked_at=now();

    IF v_event IS NOT NULL THEN v_ev := v_ev + 1; ELSE v_pf := v_pf + 1; END IF;
  END LOOP;

  RETURN QUERY SELECT v_ev, v_pf;
END $$;

COMMENT ON FUNCTION pm_match() IS
  'Links every attributable prediction market to a tevo_performer_id (team) and, '
  'for dated game markets, the specific tevo_event_id (team ∈ event AND date '
  'matches events.occurs_at_local). Idempotent — safe to re-run.';

-- ----------------------------------------------------------------------------
-- (9) Sweep — prune resolved pendings (6h) + markets not seen for 7d (closed/gone).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pm_sweep()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM prediction_market_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '6 hours';
  DELETE FROM prediction_markets WHERE updated_at < now() - interval '7 days';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM prediction_market_xref x
  WHERE NOT EXISTS (SELECT 1 FROM prediction_markets p
                    WHERE p.source=x.source AND p.market_id=x.market_id);
  RETURN v_n;
END $$;

-- ----------------------------------------------------------------------------
-- (10) Read RPCs — public data, SECDEF (past deny-all RLS), NOT email-gated.
-- ----------------------------------------------------------------------------
-- Markets tied to a specific event (game moneyline) PLUS futures on that event's
-- performers (e.g. World Series odds for the teams playing).
CREATE OR REPLACE FUNCTION get_event_prediction_markets(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $func$
DECLARE
  v_perfs bigint[];
  v_games jsonb;
  v_fut   jsonb;
BEGIN
  SELECT array_remove(array_cat(ARRAY[e.primary_performer_id], e.performer_ids), NULL)
  INTO v_perfs FROM events e WHERE e.id = p_event_id;

  SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.source, g.subtitle), '[]'::jsonb)
  INTO v_games FROM (
    SELECT p.source, p.market_type, p.title, p.question, p.subtitle,
           p.yes_price, p.no_price, p.last_price, p.volume, p.url, p.status,
           x.tevo_performer_id, x.confidence
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
           x.tevo_performer_id
    FROM prediction_market_xref x
    JOIN prediction_markets p ON p.source=x.source AND p.market_id=x.market_id
    WHERE x.tevo_event_id IS NULL
      AND x.tevo_performer_id = ANY(coalesce(v_perfs, ARRAY[]::bigint[]))
      AND coalesce(p.status,'') NOT IN ('closed','settled','inactive')
      AND p.yes_price IS NOT NULL
  ) f;

  RETURN jsonb_build_object(
    'event_id',     p_event_id,
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'game_markets', coalesce(v_games,'[]'::jsonb),
    'futures',      coalesce(v_fut,'[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION get_event_prediction_markets(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_event_prediction_markets(bigint) TO anon, authenticated, service_role;
COMMENT ON FUNCTION get_event_prediction_markets(bigint) IS
  'Kalshi/Polymarket markets for an event: game moneyline (matched to this event) '
  '+ futures on the event''s teams. Public data; SECDEF (reads past deny-all RLS), '
  'not email-gated. Prices are implied probabilities 0..1.';

-- All markets attributed to a performer (games + futures).
CREATE OR REPLACE FUNCTION get_performer_prediction_markets(p_performer_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $func$
DECLARE v_rows jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.market_type, m.event_date NULLS LAST), '[]'::jsonb)
  INTO v_rows FROM (
    SELECT p.source, p.market_type, p.league, p.title, p.question, p.subtitle,
           p.event_date, p.yes_price, p.no_price, p.last_price, p.volume, p.url, p.status
    FROM prediction_market_xref x
    JOIN prediction_markets p ON p.source=x.source AND p.market_id=x.market_id
    WHERE x.tevo_performer_id = p_performer_id
      AND coalesce(p.status,'') NOT IN ('closed','settled','inactive')
  ) m;

  RETURN jsonb_build_object(
    'performer_id', p_performer_id,
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'markets',      coalesce(v_rows,'[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION get_performer_prediction_markets(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_performer_prediction_markets(bigint) TO anon, authenticated, service_role;
COMMENT ON FUNCTION get_performer_prediction_markets(bigint) IS
  'All Kalshi/Polymarket markets attributed to a performer (team). Public; SECDEF.';

-- ----------------------------------------------------------------------------
-- (11) Health view — operator freshness/coverage visibility.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_prediction_markets_health AS
SELECT
  c.source, c.league, c.poll_kind, c.enabled, c.last_polled_at,
  (SELECT count(*) FROM prediction_markets p WHERE p.source=c.source AND p.league=c.league) AS markets,
  (SELECT count(*) FROM prediction_markets p JOIN prediction_market_xref x
     ON x.source=p.source AND x.market_id=p.market_id
   WHERE p.source=c.source AND p.league=c.league AND x.tevo_event_id IS NOT NULL) AS matched_games,
  (SELECT count(*) FROM prediction_markets p JOIN prediction_market_xref x
     ON x.source=p.source AND x.market_id=p.market_id
   WHERE p.source=c.source AND p.league=c.league AND x.tevo_performer_id IS NOT NULL) AS matched_teams,
  (SELECT max(fired_at) FROM prediction_market_pending q WHERE q.source=c.source) AS last_fire_at,
  (SELECT max(error) FROM prediction_market_pending q
    WHERE q.source=c.source AND q.resolved_at >= now() - interval '6 hours' AND q.error IS NOT NULL) AS recent_error
FROM prediction_market_config c;

GRANT SELECT ON v_prediction_markets_health TO service_role;

COMMENT ON VIEW v_prediction_markets_health IS
  'Per source+league: market counts, matched games/teams, last pull, recent error.';

-- ----------------------------------------------------------------------------
-- (12) Crons. Queue every 30 min (prices move but not tick-by-tick; budget-kind);
--      process every 5 min (2-59 offset); match every 15 min; sweep daily.
-- ----------------------------------------------------------------------------
-- Minute marks avoid the saturated :00/:02/:05/:07 clusters (MIGRATION_CONVENTIONS).
SELECT cron.schedule('pm_queue_30min',   '11,41 * * * *',  $$ SELECT public.pm_queue(); $$);
SELECT cron.schedule('pm_process_5min',  '3-59/5 * * * *', $$ SELECT public.pm_process(); $$);
SELECT cron.schedule('pm_match_15min',   '8-59/15 * * * *',$$ SELECT public.pm_match(); $$);
SELECT cron.schedule('pm_sweep_daily',   '18 17 * * *',    $$ SELECT public.pm_sweep(); $$);

-- ----------------------------------------------------------------------------
-- (13) Kick off the first pull on apply.
-- ----------------------------------------------------------------------------
SELECT public.pm_queue();
