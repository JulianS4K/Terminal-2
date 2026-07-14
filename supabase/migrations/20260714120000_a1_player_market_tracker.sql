-- ============================================================================
-- Migration 20260714120000 — Player prediction-market tracker (Kalshi next-team)
--                            + name-scoped social feed for the player page
--
-- Lane:     A1 data plane (cross-source ingest + xref — sibling of the team-level
--           prediction_markets pipeline, mig 20260702235600 / 20260703010000)
-- Touches:  player_market_athlete_map      (W: poll catalog + athlete resolution),
--           player_prediction_markets       (W: normalized candidate-destination rows),
--           player_prediction_pending        (W: pg_net queue bookkeeping),
--           ppm_queue / ppm_process           (W: async GET + parse),
--           get_player_prediction_markets     (W: player-page RPC — his "transfer" odds),
--           get_player_social                 (W: player-page RPC — name-scoped X+Reddit),
--           x_news_sources                    (W: seed one LeBron query source, DISABLED),
--           espn_athletes + performer_espn_team_xref + espn_teams_canonical (R: matching),
--           pm_resolve_performer (R: reuse the team resolver for destination links),
--           x_news + reddit_news (R: the social feed is a name filter over the wire)
-- Pre-reqs: 20260702235600 (pm_resolve_performer + prediction_markets infra),
--           20260704080000 (espn_athletes / get_broker_player_page player page),
--           20260706114500 (x_news_sources + x_news), 20260626120030 (reddit_news),
--           20260512100000 (trg_set_updated_at),
--           external: api.elections.kalshi.com reachable from pg_net (proven live by
--           the team pipeline — same host).
--
-- WHY: the team-level pipeline resolves Kalshi/Polymarket markets to a TEAM
--   (tevo_performer_id) — it has no athlete dimension, so a *player* market like
--   Kalshi's "LeBron James — next team" (series KXNEXTTEAMNBA, one market per
--   candidate destination) has nowhere to attach. This adds that missing
--   dimension as an ISOLATED subsystem: its own tables/functions/crons, ZERO
--   edits to the shipped team pipeline (pm_queue/pm_process/pm_match untouched →
--   no regression to their tests / behaviour). Destination teams are linked back
--   to our performers by REUSING the existing read-only pm_resolve_performer().
--
-- Read-only upstream (RULE 2): Kalshi is polled GET-only via pg_net; no client,
--   no write path — same posture as the team pipeline + FRED/ESPN/reddit.
--
-- SOCIAL: "plug in his twitter and reddit feeds" — rather than a per-athlete
--   ingest pipeline, the player's feed is a NAME FILTER over the existing wire
--   tables (x_news, reddit_news). It surfaces immediately from data already
--   collected for the global NEWS WIRE and gets richer as sources are enabled.
--   A dedicated LeBron X advanced-search source is seeded DISABLED (TwitterAPI.io
--   is paid — enabling spend is the operator's opt-in, mirroring mig 20260706114500).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Poll catalog + athlete resolution. One row per tracked Kalshi player event.
--     The queue fires one GET per DISTINCT enabled (source, series_ticker); the
--     processor attributes each returned event to an athlete by event_ticker
--     (exact) OR athlete_name in the event title (fallback — robust to a ticker
--     we guessed slightly wrong).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS player_market_athlete_map (
  source          text NOT NULL,              -- 'kalshi'
  series_ticker   text NOT NULL,              -- 'KXNEXTTEAMNBA' (what we poll)
  event_ticker    text NOT NULL,              -- 'KXNEXTTEAMNBA-26LJAM' (the athlete's event)
  espn_athlete_id text NOT NULL,              -- espn_athletes.espn_athlete_id (TEXT)
  espn_league     text NOT NULL,              -- NBA/... (uppercase, matches espn_league)
  athlete_name    text NOT NULL,              -- 'LeBron James' (title-match fallback + label)
  market_kind     text NOT NULL DEFAULT 'next_team',
  enabled         boolean NOT NULL DEFAULT true,
  last_polled_at  timestamptz,                -- round-robin cursor (queue stagger)
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, event_ticker)
);

COMMENT ON TABLE player_market_athlete_map IS
  'Maps a Kalshi player event (series+event ticker) to an espn_athlete_id so the '
  'player-market processor can attribute candidate-destination markets to a player. '
  'The queue polls DISTINCT enabled (source, series_ticker); the processor matches '
  'events by event_ticker OR athlete_name in the event title. Add a row per tracked '
  'player. Mig 20260714120000.';

-- Seed: LeBron James → the live "next NBA team" market. He left the Lakers
-- (espn_athletes.status='released'), so this is his real "transfer" market.
INSERT INTO player_market_athlete_map
  (source, series_ticker, event_ticker, espn_athlete_id, espn_league, athlete_name, market_kind, notes)
VALUES
  ('kalshi', 'KXNEXTTEAMNBA', 'KXNEXTTEAMNBA-26LJAM', '1966', 'NBA', 'LeBron James',
   'next_team', 'seed: LeBron next-team odds (left LAL; settles by 2026-10-23)')
ON CONFLICT (source, event_ticker) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) Normalized storage — one row per candidate destination market. Prices are
--     0..1 implied probability (Kalshi yes_ask_dollars). dest_performer_id is the
--     resolved destination team (via pm_resolve_performer) for a clickable link.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS player_prediction_markets (
  source           text NOT NULL,             -- 'kalshi'
  market_id        text NOT NULL,             -- kalshi market ticker (per candidate)
  event_ticker     text,                      -- grouping event ticker
  espn_athlete_id  text,                      -- resolved subject athlete
  espn_league      text,
  market_kind      text,                      -- 'next_team'
  title            text,                      -- event title
  question         text,                      -- market question
  dest_team_token  text,                      -- ticker-suffix abbrev (matching aid)
  dest_team_name   text,                      -- yes_sub_title (destination team/city)
  dest_performer_id bigint,                   -- resolved tevo_performer_id (nullable)
  yes_price        numeric,                   -- implied prob of this destination (0..1)
  no_price         numeric,
  last_price       numeric,
  volume           numeric,
  close_time       timestamptz,               -- settlement
  url              text,
  status           text,
  raw              jsonb,
  first_seen       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, market_id)
);
CREATE INDEX IF NOT EXISTS ppm_athlete_idx
  ON player_prediction_markets(espn_athlete_id, espn_league);
CREATE INDEX IF NOT EXISTS ppm_event_idx ON player_prediction_markets(event_ticker);
CREATE INDEX IF NOT EXISTS ppm_updated_idx ON player_prediction_markets(updated_at DESC);

COMMENT ON TABLE player_prediction_markets IS
  'Normalized Kalshi player-market rows — one per candidate destination (e.g. each '
  'team LeBron might sign with), implied probability 0..1. Populated by ppm_process. '
  'Read via get_player_prediction_markets. Isolated from the team-level '
  'prediction_markets table by design. Mig 20260714120000.';

DROP TRIGGER IF EXISTS player_prediction_markets_updated_at ON player_prediction_markets;
CREATE TRIGGER player_prediction_markets_updated_at
  BEFORE UPDATE ON player_prediction_markets
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ----------------------------------------------------------------------------
-- (3) pg_net queue bookkeeping.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS player_prediction_pending (
  id            bigserial PRIMARY KEY,
  source        text NOT NULL,
  series_ticker text NOT NULL,
  request_id    bigint NOT NULL,
  fired_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  http_status   int,
  rows_upserted int,
  error         text
);
CREATE INDEX IF NOT EXISTS player_prediction_pending_unresolved_idx
  ON player_prediction_pending(fired_at) WHERE resolved_at IS NULL;

-- RLS: deny-all (service_role bypasses; SECDEF RPCs are the read path).
ALTER TABLE player_market_athlete_map   ENABLE ROW LEVEL SECURITY;
ALTER TABLE player_prediction_markets   ENABLE ROW LEVEL SECURITY;
ALTER TABLE player_prediction_pending   ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- (4) Queue — fire one GET per DISTINCT enabled (source, series_ticker). Kalshi
--     nested-markets events endpoint (same host/params the team pipeline proved
--     live). last_polled_at staggers the round-robin across series.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ppm_queue()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  s     RECORD;
  v_req bigint;
  v_url text;
  v_n   int := 0;
BEGIN
  FOR s IN
    SELECT DISTINCT source, series_ticker
    FROM player_market_athlete_map
    WHERE enabled
  LOOP
    IF s.source <> 'kalshi' THEN CONTINUE; END IF;  -- only kalshi wired for now
    v_url := 'https://api.elections.kalshi.com/trade-api/v2/events'
          || '?limit=200&with_nested_markets=true&status=open&series_ticker='
          || s.series_ticker;

    SELECT net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'Accept', 'application/json',
        'User-Agent', 'Terminal2-S4K/1.0 (+julian@s4kent.com)'),
      timeout_milliseconds := 20000
    ) INTO v_req;

    INSERT INTO player_prediction_pending(source, series_ticker, request_id)
    VALUES (s.source, s.series_ticker, v_req);

    UPDATE player_market_athlete_map
       SET last_polled_at = now()
     WHERE source = s.source AND series_ticker = s.series_ticker;
    v_n := v_n + 1;
    PERFORM pg_sleep(0.3);
  END LOOP;
  RETURN v_n;
END $$;

COMMENT ON FUNCTION ppm_queue() IS
  'Fires one pg_net GET per enabled player-market series (Kalshi nested events). '
  'Read-only (GET). Drains via ppm_process(). Mig 20260714120000.';

-- ----------------------------------------------------------------------------
-- (5) Process — parse Kalshi events into player_prediction_markets. Each event
--     is attributed to an athlete via player_market_athlete_map (event_ticker
--     exact, else athlete_name in the event title). Each nested market = a
--     candidate destination; the destination team is resolved to a performer via
--     the existing pm_resolve_performer(). Also prunes resolved pendings > 6h.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ppm_process()
RETURNS TABLE(processed int, rows_upserted int) LANGUAGE plpgsql AS $$
DECLARE
  r        RECORD;
  v_body   jsonb;
  ev       jsonb;
  mk       jsonb;
  v_map    RECORD;
  v_token  text;
  v_perf   bigint;
  v_ins    int;
  v_proc   int := 0;
  v_total  int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.source, p.series_ticker, h.content, h.status_code
    FROM player_prediction_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_proc := v_proc + 1;
    v_ins := 0;

    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;

      IF v_body IS NOT NULL THEN
        FOR ev IN SELECT jsonb_array_elements(coalesce(v_body->'events', '[]'::jsonb)) LOOP
          -- Attribute this event to a tracked athlete.
          SELECT * INTO v_map
          FROM player_market_athlete_map m
          WHERE m.enabled AND m.source = r.source
            AND ( m.event_ticker = (ev->>'event_ticker')
                  OR ( m.series_ticker = r.series_ticker
                       AND coalesce(ev->>'title','') ILIKE '%'||m.athlete_name||'%' ) )
          ORDER BY (m.event_ticker = (ev->>'event_ticker')) DESC   -- prefer exact ticker
          LIMIT 1;

          IF v_map.espn_athlete_id IS NULL THEN CONTINUE; END IF;   -- untracked event

          FOR mk IN SELECT jsonb_array_elements(coalesce(ev->'markets', '[]'::jsonb)) LOOP
            v_token := upper(split_part(mk->>'ticker', '-',
                         array_length(string_to_array(mk->>'ticker','-'),1)));
            -- Reuse the team resolver: destination team → our performer.
            v_perf := pm_resolve_performer(v_map.espn_league, v_token, mk->>'yes_sub_title');

            INSERT INTO player_prediction_markets (
              source, market_id, event_ticker, espn_athlete_id, espn_league,
              market_kind, title, question, dest_team_token, dest_team_name,
              dest_performer_id, yes_price, no_price, last_price, volume,
              close_time, url, status, raw)
            VALUES (
              r.source, mk->>'ticker', ev->>'event_ticker',
              v_map.espn_athlete_id, v_map.espn_league, v_map.market_kind,
              ev->>'title', mk->>'title', v_token, mk->>'yes_sub_title',
              v_perf,
              nullif(mk->>'yes_ask_dollars','')::numeric,
              nullif(mk->>'no_ask_dollars','')::numeric,
              nullif(mk->>'last_price_dollars','')::numeric,
              nullif(mk->>'volume_fp','')::numeric,
              nullif(mk->>'close_time','')::timestamptz,
              'https://kalshi.com/markets/'||lower(coalesce(ev->>'series_ticker',''))
                ||'/'||coalesce(ev->>'event_ticker',''),
              mk->>'status',
              jsonb_build_object('yes_bid', mk->>'yes_bid_dollars',
                                 'open_interest', mk->>'open_interest_fp',
                                 'volume_24h', mk->>'volume_24h_fp'))
            ON CONFLICT (source, market_id) DO UPDATE SET
              event_ticker=EXCLUDED.event_ticker, espn_athlete_id=EXCLUDED.espn_athlete_id,
              espn_league=EXCLUDED.espn_league, market_kind=EXCLUDED.market_kind,
              title=EXCLUDED.title, question=EXCLUDED.question,
              dest_team_token=EXCLUDED.dest_team_token, dest_team_name=EXCLUDED.dest_team_name,
              dest_performer_id=EXCLUDED.dest_performer_id, yes_price=EXCLUDED.yes_price,
              no_price=EXCLUDED.no_price, last_price=EXCLUDED.last_price,
              volume=EXCLUDED.volume, close_time=EXCLUDED.close_time, url=EXCLUDED.url,
              status=EXCLUDED.status, raw=EXCLUDED.raw, updated_at=now();
            v_ins := v_ins + 1;
          END LOOP;
        END LOOP;
      END IF;
    END IF;

    UPDATE player_prediction_pending
       SET resolved_at = now(), http_status = r.status_code, rows_upserted = v_ins,
           error = CASE WHEN r.status_code <> 200 THEN 'http '||coalesce(r.status_code,0) ELSE NULL END
     WHERE id = r.pending_id;

    v_total := v_total + v_ins;
  END LOOP;

  -- prune old bookkeeping (retention: 6h resolved pendings; stale markets 7d)
  DELETE FROM player_prediction_pending
   WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '6 hours';
  DELETE FROM player_prediction_markets WHERE updated_at < now() - interval '7 days';

  RETURN QUERY SELECT v_proc, v_total;
END $$;

COMMENT ON FUNCTION ppm_process() IS
  'Drains player_prediction_pending → player_prediction_markets. Attributes each '
  'Kalshi event to an athlete (player_market_athlete_map) and resolves each '
  'candidate destination team via pm_resolve_performer. Mig 20260714120000.';

-- ----------------------------------------------------------------------------
-- (6) Read RPC — a player''s prediction markets ("transfer" odds). Email-gated
--     to mirror the player-page posture (get_broker_player_page). Candidates
--     sorted by implied probability desc.
-- ----------------------------------------------------------------------------
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
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT max(market_kind), max(title), max(close_time)
  INTO v_kind, v_title, v_close
  FROM player_prediction_markets
  WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league
    AND coalesce(status,'') NOT IN ('closed','settled','inactive');

  IF v_kind IS NULL THEN
    RETURN jsonb_build_object('applicable', false);
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.yes_price DESC NULLS LAST), '[]'::jsonb)
  INTO v_cands FROM (
    SELECT source, dest_team_name, dest_team_token, dest_performer_id,
           yes_price, last_price, volume, url, status
    FROM player_prediction_markets
    WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league
      AND coalesce(status,'') NOT IN ('closed','settled','inactive')
      AND yes_price IS NOT NULL
  ) c;

  RETURN jsonb_build_object(
    'applicable',   true,
    'market_kind',  v_kind,
    'title',        v_title,
    'close_time',   v_close,
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'candidates',   v_cands);
END $func$;

REVOKE ALL ON FUNCTION public.get_player_prediction_markets(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_player_prediction_markets(text, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_player_prediction_markets(text, text) IS
  'Player prediction markets (e.g. Kalshi next-team "transfer" odds) for the '
  'player page: candidate destinations sorted by implied probability. Email-gated '
  '(@s4kent.com), like get_broker_player_page. Mig 20260714120000.';

-- ----------------------------------------------------------------------------
-- (7) Read RPC — a player''s social feed. NAME FILTER over the existing wire
--     tables (x_news + reddit_news), newest first. Zero new ingest: surfaces
--     posts already collected for the global NEWS WIRE that mention the player.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_player_social(p_name text, p_league text DEFAULT NULL, p_limit int DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $func$
DECLARE
  v_email text;
  v_q     text := nullif(btrim(coalesce(p_name,'')), '');
  v_lim   int  := greatest(1, least(coalesce(p_limit, 30), 100));
  v_rows  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  IF v_q IS NULL THEN
    RETURN jsonb_build_object('items', '[]'::jsonb);
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.published_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_rows FROM (
    SELECT 'X'::text AS source, '@'||author_handle AS handle, title, url, created_utc AS published_at
    FROM x_news
    WHERE pulled_at > now() - interval '72 hours' AND title ILIKE '%'||v_q||'%'
    UNION ALL
    SELECT 'Reddit'::text AS source, 'r/'||subreddit AS handle, title,
           coalesce(nullif(link_url,''), permalink) AS url, created_utc AS published_at
    FROM reddit_news
    WHERE pulled_at > now() - interval '72 hours' AND title ILIKE '%'||v_q||'%'
    ORDER BY published_at DESC NULLS LAST
    LIMIT v_lim
  ) f;

  RETURN jsonb_build_object(
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'items', coalesce(v_rows,'[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_player_social(text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_player_social(text, text, int) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_player_social(text, text, int) IS
  'Player social feed for the player page: X (twitter) + Reddit wire rows whose '
  'text mentions the player, newest first (72h). Reads existing x_news/reddit_news '
  '(no per-athlete ingest). Email-gated (@s4kent.com). Mig 20260714120000.';

-- ----------------------------------------------------------------------------
-- (8) Seed a LeBron X advanced-search source (DISABLED — TwitterAPI.io is paid;
--     enabling spend is the operator''s opt-in, same posture as mig 20260706114500).
--     Once enabled + the vault key exists, his tweets flow into x_news and are
--     picked up by get_player_social via the name filter.
-- ----------------------------------------------------------------------------
INSERT INTO x_news_sources (source_value, kind, league, enabled, notes)
VALUES ('"LeBron James" -filter:retweets -filter:replies min_faves:200', 'query', 'NBA', false,
        'seed: LeBron player feed — opt-in (paid). Mig 20260714120000.')
ON CONFLICT (source_value) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (9) Crons. Player next-team odds move on news, not tick-by-tick → poll twice
--     hourly; process every 5 min. Minute marks avoid the saturated :00/:02/:05
--     clusters (MIGRATION_CONVENTIONS) and the team pipeline''s 11,41 / 3-59/5.
-- ----------------------------------------------------------------------------
SELECT cron.schedule('ppm_queue_2x_hourly', '13,43 * * * *',  $$ SELECT public.ppm_queue(); $$);
SELECT cron.schedule('ppm_process_5min',    '4-59/5 * * * *', $$ SELECT public.ppm_process(); $$);

-- ----------------------------------------------------------------------------
-- (10) Kick off the first pull on apply.
-- ----------------------------------------------------------------------------
SELECT public.ppm_queue();
