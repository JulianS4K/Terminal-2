-- ============================================================================
-- Migration 20260714200000 — General player watchlist (generalizes the LeBron
--                            stopgap to any tracked athlete)
--
-- Lane:     A1 data plane
-- Touches:  player_watchlist (W: new canonical tracked-athlete set),
--           watchlist_social_poll (W: new — generalizes lebron_poll),
--           pww_wiki_queue (W: iterate the watchlist, not the market map),
--           get_trade_watch (W: iterate the watchlist),
--           get_watchlist / watchlist_add / watchlist_remove (W: manage RPCs),
--           lebron_poll (dropped) + its cron (unscheduled),
--           reddit_news_pending / x_news_pending (W: enqueue), espn_athletes (R)
-- Pre-reqs: 20260714120000 (player markets), 20260714130000 (wiki watch +
--           get_trade_watch), 20260714150000 (lebron_poll), 20260706114500
--           (x_news_urlencode / get_app_secret)
--
-- WHY: the LeBron feature set (markets · wiki team-watch · max-freq social ·
--   merged feed · Trade Watch) was a per-player stopgap. This adds the canonical
--   watchlist table and repoints the round-robin pollers + Trade Watch at it, so
--   ANY athlete can be tracked. Adding a player is one row (watchlist_add);
--   everything downstream (feeds are name-filtered, wiki-watch + social poll
--   iterate the watchlist) picks them up automatically. Kalshi markets still
--   need a per-event mapping (player_market_athlete_map) since the Kalshi event
--   ticker isn't derivable; Polymarket + all feeds generalize by name.
--
-- Read-only upstream (RULE 2): social poll is GET-only via pg_net. The manage
--   RPCs write ONLY the app-level watchlist table (email-gated SECDEF, the
--   designed write surface past deny-all RLS — like bot_chat).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Canonical watchlist.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS player_watchlist (
  espn_athlete_id     text NOT NULL,
  espn_league         text NOT NULL,
  athlete_name        text NOT NULL,
  enabled             boolean NOT NULL DEFAULT true,
  poll_social         boolean NOT NULL DEFAULT true,
  poll_wiki           boolean NOT NULL DEFAULT true,
  last_social_poll_at timestamptz,      -- round-robin cursor for the social poll
  added_by            text,
  notes               text,
  added_at            timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (espn_athlete_id, espn_league)
);
ALTER TABLE player_watchlist ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE player_watchlist IS
  'Canonical set of actively-tracked athletes. Drives the social poll '
  '(watchlist_social_poll), the Wikipedia team-watch (pww_wiki_queue) and the '
  'Trade Watch page (get_trade_watch). Managed via watchlist_add/remove. '
  'Mig 20260714200000.';

-- Seed: LeBron (was the hardcoded stopgap target).
INSERT INTO player_watchlist (espn_athlete_id, espn_league, athlete_name, added_by, notes)
VALUES ('1966', 'NBA', 'LeBron James', 'seed', 'migrated from the LeBron stopgap')
ON CONFLICT (espn_athlete_id, espn_league) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) Social poll — generalizes lebron_poll to a round-robin over the watchlist.
--     Fires ONE athlete per call (least-recently-polled): site-wide Reddit
--     search + X advanced search (paid; no-ops without key). p_limit>1 fires
--     several per tick. Read via get_player_feed / get_player_social (name filter).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.watchlist_social_poll(p_limit int DEFAULT 1)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a RECORD; v_req bigint; v_key text; v_slug text; v_n int := 0;
BEGIN
  BEGIN v_key := get_app_secret('TWITTERAPI_IO_KEY'); EXCEPTION WHEN OTHERS THEN v_key := NULL; END;

  FOR a IN
    SELECT espn_athlete_id, espn_league, athlete_name
    FROM player_watchlist
    WHERE enabled AND poll_social
    ORDER BY last_social_poll_at ASC NULLS FIRST, espn_athlete_id
    LIMIT greatest(1, coalesce(p_limit, 1))
  LOOP
    v_slug := left(regexp_replace(lower(a.athlete_name), '\s+', '', 'g'), 24);

    -- Reddit site-wide search (free).
    SELECT net.http_get(
      url := 'https://old.reddit.com/search.rss?q='
             || x_news_urlencode('"'||a.athlete_name||'"') || '&sort=new&limit=25',
      headers := jsonb_build_object('User-Agent','Terminal2-S4K-RSS/1.0',
                                    'Accept','application/rss+xml, application/xml'),
      timeout_milliseconds := 12000
    ) INTO v_req;
    INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
    VALUES (v_slug, a.espn_league, a.athlete_name||' (watchlist search)', v_req, now());
    v_n := v_n + 1;

    -- X search (paid; skip without key).
    IF v_key IS NOT NULL AND btrim(v_key) <> '' THEN
      SELECT net.http_get(
        url := 'https://api.twitterapi.io/twitter/tweet/advanced_search?queryType=Latest&query='
               || x_news_urlencode('"'||a.athlete_name||'" -filter:retweets -filter:replies'),
        headers := jsonb_build_object('X-API-Key', v_key, 'Accept','application/json'),
        timeout_milliseconds := 15000
      ) INTO v_req;
      INSERT INTO x_news_pending(source_value, kind, league, request_id, fired_at)
      VALUES ('"'||a.athlete_name||'" (watchlist search)', 'query', a.espn_league, v_req, now());
      v_n := v_n + 1;
    END IF;

    UPDATE player_watchlist SET last_social_poll_at = now()
    WHERE espn_athlete_id = a.espn_athlete_id AND espn_league = a.espn_league;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_n;
END $$;

COMMENT ON FUNCTION public.watchlist_social_poll(int) IS
  'Round-robin social poll over player_watchlist (one athlete/call by default): '
  'site-wide Reddit search + X advanced search, drained by the existing '
  '*_process crons. Generalizes lebron_poll. Mig 20260714200000.';

-- Retire the hardcoded LeBron poll.
SELECT cron.unschedule('lebron_poll_3min') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='lebron_poll_3min');
DROP FUNCTION IF EXISTS public.lebron_poll();

-- New cron: 1 athlete/min round-robin (a small watchlist keeps each fresh).
SELECT cron.schedule('watchlist_social_poll_1min', '* * * * *', $$ SELECT public.watchlist_social_poll(1); $$);
SELECT public.watchlist_social_poll(1);

-- ----------------------------------------------------------------------------
-- (3) Wikipedia team-watch — iterate the watchlist (was the market map).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pww_wiki_queue(p_min_age interval DEFAULT interval '4 minutes')
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_req bigint; v_title text; v_n int := 0;
  v_ua jsonb := jsonb_build_object('User-Agent',
    'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
    'Accept','application/json');
BEGIN
  FOR r IN
    SELECT DISTINCT m.espn_athlete_id, m.espn_league, m.athlete_name,
           coalesce(aw.wiki_title, w.wiki_title, m.athlete_name) AS title
    FROM player_watchlist m
    LEFT JOIN athlete_wikipedia aw ON aw.espn_athlete_id = m.espn_athlete_id
    LEFT JOIN player_wiki_watch  w  ON w.espn_athlete_id  = m.espn_athlete_id
    WHERE m.enabled AND m.poll_wiki
      AND (w.last_checked_at IS NULL OR w.last_checked_at < now() - p_min_age)
  LOOP
    v_title := replace(btrim(r.title), ' ', '_');
    SELECT net.http_get(
      url := 'https://en.wikipedia.org/api/rest_v1/page/summary/' || v_title,
      headers := v_ua, timeout_milliseconds := 12000
    ) INTO v_req;

    INSERT INTO player_wiki_watch_pending(espn_athlete_id, wiki_title, request_id)
    VALUES (r.espn_athlete_id, r.title, v_req);

    INSERT INTO player_wiki_watch(espn_athlete_id, espn_league, athlete_name, wiki_title, last_checked_at)
    VALUES (r.espn_athlete_id, r.espn_league, r.athlete_name, r.title, now())
    ON CONFLICT (espn_athlete_id) DO UPDATE
      SET last_checked_at = now(), wiki_title = EXCLUDED.wiki_title, updated_at = now();
    v_n := v_n + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_n;
END $$;

-- ----------------------------------------------------------------------------
-- (4) Trade Watch — iterate the watchlist (was the market map). Body identical
--     to mig 20260714130000 except the driving table.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_trade_watch()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE v_email text; v_players jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.lead_pct DESC NULLS LAST), '[]'::jsonb)
  INTO v_players FROM (
    SELECT
      m.espn_athlete_id, m.espn_league, m.athlete_name,
      a.headshot_url, a.status AS roster_status,
      coalesce(tc.display_name, a.espn_team_id) AS roster_team,
      (SELECT jsonb_build_object('team', c.dest_team_name, 'performer_id', c.dest_performer_id,
                'pct', round(c.yes_price*100)::int, 'url', c.url)
         FROM player_prediction_markets c
         WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league
           AND c.yes_price IS NOT NULL AND coalesce(c.status,'') NOT IN ('closed','settled','inactive')
         ORDER BY c.yes_price DESC NULLS LAST LIMIT 1) AS market_leader,
      (SELECT max(c.yes_price*100) FROM player_prediction_markets c
         WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league
           AND c.yes_price IS NOT NULL AND coalesce(c.status,'') NOT IN ('closed','settled','inactive')) AS lead_pct,
      (SELECT coalesce(jsonb_agg(jsonb_build_object('team', c.dest_team_name,
                'performer_id', c.dest_performer_id, 'pct', round(c.yes_price*100)::int)
                ORDER BY c.yes_price DESC NULLS LAST), '[]'::jsonb)
         FROM player_prediction_markets c
         WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league
           AND c.yes_price IS NOT NULL AND coalesce(c.status,'') NOT IN ('closed','settled','inactive')) AS candidates,
      (SELECT max(close_time) FROM player_prediction_markets c
         WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league) AS close_time,
      w.extract AS wiki_extract, w.team_hint AS wiki_team,
      w.changed_at AS wiki_changed_at, w.last_checked_at AS wiki_checked_at,
      CASE
        WHEN (SELECT max(c.yes_price) FROM player_prediction_markets c
                WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league) >= 0.90
          OR EXISTS (SELECT 1 FROM player_prediction_markets c
                      WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league
                        AND coalesce(c.status,'') IN ('settled','closed'))
          OR (w.changed_at IS NOT NULL AND w.changed_at > now() - interval '7 days')
        THEN 'MOVED' ELSE 'WATCHING' END AS state
    FROM player_watchlist m
    LEFT JOIN espn_athletes a ON a.espn_athlete_id = m.espn_athlete_id AND a.espn_league = m.espn_league
    LEFT JOIN espn_teams_canonical tc ON tc.espn_team_id = a.espn_team_id AND tc.espn_league = m.espn_league
    LEFT JOIN player_wiki_watch w ON w.espn_athlete_id = m.espn_athlete_id
    WHERE m.enabled
  ) p;

  RETURN jsonb_build_object(
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'players', coalesce(v_players, '[]'::jsonb));
END $func$;

-- ----------------------------------------------------------------------------
-- (5) Manage RPCs (email-gated SECDEF; the write surface past deny-all RLS).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_watchlist()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $func$
DECLARE v_email text; v_rows jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.athlete_name), '[]'::jsonb) INTO v_rows FROM (
    SELECT w.espn_athlete_id, w.espn_league, w.athlete_name, w.added_at,
           a.headshot_url, a.status AS roster_status,
           coalesce(tc.display_name, a.espn_team_id) AS roster_team
    FROM player_watchlist w
    LEFT JOIN espn_athletes a ON a.espn_athlete_id=w.espn_athlete_id AND a.espn_league=w.espn_league
    LEFT JOIN espn_teams_canonical tc ON tc.espn_team_id=a.espn_team_id AND tc.espn_league=w.espn_league
    WHERE w.enabled
  ) x;
  RETURN jsonb_build_object('players', coalesce(v_rows,'[]'::jsonb));
END $func$;

CREATE OR REPLACE FUNCTION public.watchlist_add(p_athlete_id text, p_league text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $func$
DECLARE v_email text; v_name text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  SELECT full_name INTO v_name FROM espn_athletes
   WHERE espn_athlete_id=p_athlete_id AND espn_league=p_league LIMIT 1;
  IF v_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'athlete_not_found'); END IF;
  INSERT INTO player_watchlist(espn_athlete_id, espn_league, athlete_name, added_by)
  VALUES (p_athlete_id, p_league, v_name, v_email)
  ON CONFLICT (espn_athlete_id, espn_league) DO UPDATE
    SET enabled=true, poll_social=true, poll_wiki=true, athlete_name=EXCLUDED.athlete_name;
  RETURN jsonb_build_object('ok', true, 'athlete_name', v_name);
END $func$;

CREATE OR REPLACE FUNCTION public.watchlist_remove(p_athlete_id text, p_league text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $func$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  UPDATE player_watchlist SET enabled=false
   WHERE espn_athlete_id=p_athlete_id AND espn_league=p_league;
  RETURN jsonb_build_object('ok', true);
END $func$;

REVOKE ALL ON FUNCTION public.get_watchlist()             FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchlist_add(text,text)    FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchlist_remove(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_watchlist()             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.watchlist_add(text,text)    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.watchlist_remove(text,text) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_watchlist() IS 'Enabled player_watchlist rows + bio for the Trade Watch manager. Email-gated. Mig 20260714200000.';
COMMENT ON FUNCTION public.watchlist_add(text,text) IS 'Add an athlete to the watchlist (resolves name from espn_athletes). Email-gated. Mig 20260714200000.';
COMMENT ON FUNCTION public.watchlist_remove(text,text) IS 'Soft-remove an athlete from the watchlist (enabled=false). Email-gated. Mig 20260714200000.';
