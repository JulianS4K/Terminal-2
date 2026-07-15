-- ============================================================================
-- Migration 20260714230000 — Tiered feed cadence + per-entity personal sources
--
-- Lane:     A1 data plane
-- Touches:  player_watchlist (W: +tier, +reddit_query, +twitter_query,
--           +whatsapp_channel), watchlist_social_poll + pww_wiki_queue (W: tier
--           cadence + personal queries), watchlist_add + watchlist_autopopulate
--           (W: set tier), get_trade_watch (W: expose tier)
-- Pre-reqs: 20260714200000 (watchlist), 20260714220000 (autopopulate)
--
-- WHY: operator — "keep feed refresh to a max of hourly unless on watchlist", and
--   point each entity at its own sources. Adds a TIER:
--     * 'watch' → high-frequency (social ~3 min, wiki ~4 min) — the curated hot list.
--     * 'track' → HOURLY max (social + wiki) — auto-added-from-market players.
--   watchlist_add promotes to 'watch'; watchlist_autopopulate adds as 'track'. The
--   34 market auto-adds become hourly; LeBron (seed) stays 'watch'. Per-entity
--   reddit_query / twitter_query (default: the quoted athlete name) let each
--   player point at their own search; whatsapp_channel is reserved for the
--   WhatsApp scaffold. The one-per-tick round-robin + per-tier due-filter keeps
--   total pg_net load flat regardless of how many are tracked.
-- ============================================================================

ALTER TABLE player_watchlist
  ADD COLUMN IF NOT EXISTS tier            text NOT NULL DEFAULT 'watch',
  ADD COLUMN IF NOT EXISTS reddit_query    text,
  ADD COLUMN IF NOT EXISTS twitter_query   text,
  ADD COLUMN IF NOT EXISTS whatsapp_channel text;

ALTER TABLE player_watchlist DROP CONSTRAINT IF EXISTS player_watchlist_tier_chk;
ALTER TABLE player_watchlist ADD  CONSTRAINT player_watchlist_tier_chk CHECK (tier IN ('watch','track'));

COMMENT ON COLUMN player_watchlist.tier IS
  '''watch'' = high-frequency polling (curated hot list); ''track'' = hourly max '
  '(auto-added from markets). Mig 20260714230000.';

-- Auto-added market players → hourly track tier; keep manual/seed as watch.
UPDATE player_watchlist SET tier='track' WHERE added_by = 'auto:market' AND tier <> 'track';

-- ----------------------------------------------------------------------------
-- Social poll — tier-aware due filter + per-entity personal queries.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.watchlist_social_poll(p_limit int DEFAULT 1)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a RECORD; v_req bigint; v_key text; v_slug text; v_rq text; v_xq text; v_n int := 0;
BEGIN
  BEGIN v_key := get_app_secret('TWITTERAPI_IO_KEY'); EXCEPTION WHEN OTHERS THEN v_key := NULL; END;

  FOR a IN
    SELECT espn_athlete_id, espn_league, athlete_name, reddit_query, twitter_query
    FROM player_watchlist
    WHERE enabled AND poll_social
      AND ( (tier='watch' AND (last_social_poll_at IS NULL OR last_social_poll_at < now() - interval '3 minutes'))
         OR (tier='track' AND (last_social_poll_at IS NULL OR last_social_poll_at < now() - interval '60 minutes')) )
    ORDER BY last_social_poll_at ASC NULLS FIRST, espn_athlete_id
    LIMIT greatest(1, coalesce(p_limit, 1))
  LOOP
    v_slug := left(regexp_replace(lower(a.athlete_name), '\s+', '', 'g'), 24);
    v_rq   := coalesce(nullif(btrim(a.reddit_query),''),  '"'||a.athlete_name||'"');
    v_xq   := coalesce(nullif(btrim(a.twitter_query),''), '"'||a.athlete_name||'"') || ' -filter:retweets -filter:replies';

    SELECT net.http_get(
      url := 'https://old.reddit.com/search.rss?q=' || x_news_urlencode(v_rq) || '&sort=new&limit=25',
      headers := jsonb_build_object('User-Agent','Terminal2-S4K-RSS/1.0',
                                    'Accept','application/rss+xml, application/xml'),
      timeout_milliseconds := 12000
    ) INTO v_req;
    INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
    VALUES (v_slug, a.espn_league, a.athlete_name||' (watchlist search)', v_req, now());
    v_n := v_n + 1;

    IF v_key IS NOT NULL AND btrim(v_key) <> '' THEN
      SELECT net.http_get(
        url := 'https://api.twitterapi.io/twitter/tweet/advanced_search?queryType=Latest&query='
               || x_news_urlencode(v_xq),
        headers := jsonb_build_object('X-API-Key', v_key, 'Accept','application/json'),
        timeout_milliseconds := 15000
      ) INTO v_req;
      INSERT INTO x_news_pending(source_value, kind, league, request_id, fired_at)
      VALUES (a.athlete_name||' (watchlist search)', 'query', a.espn_league, v_req, now());
      v_n := v_n + 1;
    END IF;

    UPDATE player_watchlist SET last_social_poll_at = now()
    WHERE espn_athlete_id = a.espn_athlete_id AND espn_league = a.espn_league;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_n;
END $$;

-- ----------------------------------------------------------------------------
-- Wiki queue — tier-aware cadence (watch ~4 min, track hourly).
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
    SELECT m.espn_athlete_id, m.espn_league, m.athlete_name,
           coalesce(aw.wiki_title, w.wiki_title, m.athlete_name) AS title
    FROM player_watchlist m
    LEFT JOIN athlete_wikipedia aw ON aw.espn_athlete_id = m.espn_athlete_id
    LEFT JOIN player_wiki_watch  w  ON w.espn_athlete_id  = m.espn_athlete_id
    WHERE m.enabled AND m.poll_wiki
      AND ( (m.tier='watch' AND (w.last_checked_at IS NULL OR w.last_checked_at < now() - p_min_age))
         OR (m.tier='track' AND (w.last_checked_at IS NULL OR w.last_checked_at < now() - interval '60 minutes')) )
    ORDER BY w.last_checked_at ASC NULLS FIRST, m.espn_athlete_id
    LIMIT 15
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
-- Manual add → 'watch' (promote); auto-populate → 'track' (hourly).
-- ----------------------------------------------------------------------------
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
  INSERT INTO player_watchlist(espn_athlete_id, espn_league, athlete_name, added_by, tier)
  VALUES (p_athlete_id, p_league, v_name, v_email, 'watch')
  ON CONFLICT (espn_athlete_id, espn_league) DO UPDATE
    SET enabled=true, poll_social=true, poll_wiki=true, tier='watch',
        athlete_name=EXCLUDED.athlete_name;
  RETURN jsonb_build_object('ok', true, 'athlete_name', v_name);
END $func$;

CREATE OR REPLACE FUNCTION public.watchlist_autopopulate()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_added int := 0;
BEGIN
  WITH names AS (
    SELECT DISTINCT btrim(coalesce(
      substring(title    from '(?:Free Agency|NBA|NFL|NHL|MLB|WNBA):\s*(.+?)\s+Next Team'),
      substring(title    from '^(.+?)\s+[Nn]ext [Tt]eam'),
      substring(question from 'Will (.+?) (?:be traded|sign|stay|play)'),
      substring(title    from 'Will (.+?) (?:be traded|sign)')
    )) AS nm, league
    FROM prediction_markets
    WHERE coalesce(status,'') NOT IN ('closed','settled','inactive') AND yes_price IS NOT NULL
      AND (title ILIKE '%next team%' OR title ILIKE '%traded%'
           OR question ILIKE '%be traded%' OR title ILIKE '%to sign%')
  ),
  resolved AS (
    SELECT DISTINCT a.espn_athlete_id, a.espn_league, a.full_name
    FROM names n
    JOIN espn_athletes a
      ON a.espn_league = n.league
     AND ( lower(a.full_name)=lower(n.nm) OR lower(a.display_name)=lower(n.nm)
        OR regexp_replace(lower(a.full_name),'[^a-z]','','g')=regexp_replace(lower(n.nm),'[^a-z]','','g') )
    WHERE n.nm IS NOT NULL AND length(n.nm) > 3
  )
  INSERT INTO player_watchlist(espn_athlete_id, espn_league, athlete_name, added_by, tier, notes)
  SELECT espn_athlete_id, espn_league, full_name, 'auto:market', 'track',
         'auto-added from an active player-movement market'
  FROM resolved
  ON CONFLICT (espn_athlete_id, espn_league) DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  RETURN v_added;
END $$;

-- ----------------------------------------------------------------------------
-- Expose tier on Trade Watch (frontend can badge watch vs tracked).
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
  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY (p.tier='watch') DESC, p.lead_pct DESC NULLS LAST), '[]'::jsonb)
  INTO v_players FROM (
    SELECT
      m.espn_athlete_id, m.espn_league, m.athlete_name, m.tier,
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
