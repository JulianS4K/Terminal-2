-- ============================================================================
-- Migration 20260714130000 — Trade Watch: high-frequency Wikipedia team-change
--                            poll for tracked players + consolidated watch RPC
--
-- Lane:     A1 data plane (extends the player-market tracker, mig 20260714120000)
-- Touches:  player_wiki_watch          (W: latest wiki snapshot + team-change flag),
--           player_wiki_watch_pending   (W: pg_net queue bookkeeping),
--           pww_wiki_queue / pww_wiki_process (W: async GET + parse/diff),
--           get_trade_watch             (W: consolidated per-player watch RPC),
--           player_market_athlete_map    (R: the tracked-player set),
--           athlete_wikipedia            (R: matched title if one exists),
--           espn_athletes + espn_teams_canonical (R: roster team/status),
--           player_prediction_markets    (R: Kalshi leading destination),
--           2 cron jobs (queue + process)
-- Pre-reqs: 20260714120000 (player_market_athlete_map + player_prediction_markets),
--           20260708151000 (athlete_wikipedia — reuse a matched title if present),
--           20260704080000 (espn_athletes / player page),
--           external: en.wikipedia.org REST summary reachable from pg_net
--           (proven live by the athlete-wiki pipeline — same host).
--
-- WHY: operator wants to "be the first to know when he trades" + "maximum refresh
--   Wikipedia to find new-team updates". The existing athlete-wiki pipeline
--   (20260708151000) is a ONE-TIME matcher — queue_athlete_wiki_searches only
--   picks athletes with NO row yet, so it never re-polls a matched player. This
--   adds a HIGH-FREQUENCY re-poll scoped to the tracked-player set (the handful in
--   player_market_athlete_map — cheap), re-fetching the Wikipedia REST summary
--   every ~5 min and DIFFING it: when the "plays for the <team>" hint changes, a
--   team change is flagged (changed_at). get_trade_watch() fuses three signals —
--   Kalshi market leader, this Wikipedia team-hint, and the ESPN roster team — into
--   one per-player state for a dedicated Trade Watch page.
--
-- Read-only upstream (RULE 2): Wikipedia is polled GET-only via pg_net.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Latest-snapshot table (one row per tracked athlete) + pg_net queue.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS player_wiki_watch (
  espn_athlete_id  text PRIMARY KEY,
  espn_league      text,
  athlete_name     text,
  wiki_title       text,                -- REST summary title (spaces→_ at fetch)
  extract          text,                -- current summary extract
  team_hint        text,                -- team parsed from "for the <team> of the"
  prev_team_hint   text,                -- previous team_hint (for the diff)
  changed_at       timestamptz,         -- when team_hint last CHANGED
  change_note      text,
  last_checked_at  timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE player_wiki_watch IS
  'High-frequency Wikipedia snapshot per tracked player (player_market_athlete_map). '
  'team_hint is parsed from the summary extract; changed_at flips when it changes '
  '(the "he moved" signal). Populated by pww_wiki_process. Mig 20260714130000.';

DROP TRIGGER IF EXISTS player_wiki_watch_updated_at ON player_wiki_watch;
CREATE TRIGGER player_wiki_watch_updated_at
  BEFORE UPDATE ON player_wiki_watch
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

CREATE TABLE IF NOT EXISTS player_wiki_watch_pending (
  id              bigserial PRIMARY KEY,
  espn_athlete_id text NOT NULL,
  wiki_title      text,
  request_id      bigint NOT NULL,
  fired_at        timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz
);
CREATE INDEX IF NOT EXISTS player_wiki_watch_pending_unresolved_idx
  ON player_wiki_watch_pending(fired_at) WHERE resolved_at IS NULL;

ALTER TABLE player_wiki_watch          ENABLE ROW LEVEL SECURITY;
ALTER TABLE player_wiki_watch_pending  ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- (2) team-hint parser — pull the team from a Wikipedia summary extract.
--     Matches "... (plays|played) for the <Team> of the ..." and the common
--     "... for the <Team>." tail. NULL if nothing matches.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _wiki_team_hint(p_extract text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(btrim(coalesce(
    substring(p_extract from 'for the ([A-Z][A-Za-z0-9 .&''-]+?) of the'),
    substring(p_extract from 'for the ([A-Z][A-Za-z0-9 .&''-]+?)[.,]')
  )), '');
$$;

-- ----------------------------------------------------------------------------
-- (3) Queue — fire a Wikipedia REST summary GET per tracked player whose snapshot
--     is stale (> p_min_age). Title = matched athlete_wikipedia title if present,
--     else the athlete name (works for unambiguous names like "LeBron James").
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
    FROM player_market_athlete_map m
    LEFT JOIN athlete_wikipedia aw ON aw.espn_athlete_id = m.espn_athlete_id
    LEFT JOIN player_wiki_watch  w  ON w.espn_athlete_id  = m.espn_athlete_id
    WHERE m.enabled
      AND (w.last_checked_at IS NULL OR w.last_checked_at < now() - p_min_age)
  LOOP
    v_title := replace(btrim(r.title), ' ', '_');
    SELECT net.http_get(
      url := 'https://en.wikipedia.org/api/rest_v1/page/summary/' || v_title,
      headers := v_ua, timeout_milliseconds := 12000
    ) INTO v_req;

    INSERT INTO player_wiki_watch_pending(espn_athlete_id, wiki_title, request_id)
    VALUES (r.espn_athlete_id, r.title, v_req);

    -- touch last_checked_at up front so a slow response doesn't double-fire
    INSERT INTO player_wiki_watch(espn_athlete_id, espn_league, athlete_name, wiki_title, last_checked_at)
    VALUES (r.espn_athlete_id, r.espn_league, r.athlete_name, r.title, now())
    ON CONFLICT (espn_athlete_id) DO UPDATE
      SET last_checked_at = now(), wiki_title = EXCLUDED.wiki_title, updated_at = now();
    v_n := v_n + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_n;
END $$;

COMMENT ON FUNCTION pww_wiki_queue(interval) IS
  'Fires a Wikipedia REST summary GET per tracked player with a stale snapshot. '
  'Read-only (GET). Drains via pww_wiki_process(). Mig 20260714130000.';

-- ----------------------------------------------------------------------------
-- (4) Process — parse summaries, diff the team hint, flag changes.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pww_wiki_process()
RETURNS TABLE(processed int, changes int) LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_body jsonb; v_extract text; v_hint text; v_prev text;
  v_p int := 0; v_c int := 0;
BEGIN
  FOR r IN
    SELECT pd.id AS pending_id, pd.espn_athlete_id, h.content, h.status_code
    FROM player_wiki_watch_pending pd
    JOIN net._http_response h ON h.id = pd.request_id
    WHERE pd.resolved_at IS NULL
  LOOP
    v_p := v_p + 1;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      IF v_body IS NOT NULL THEN
        v_extract := v_body->>'extract';
        v_hint    := _wiki_team_hint(v_extract);

        SELECT team_hint INTO v_prev FROM player_wiki_watch WHERE espn_athlete_id = r.espn_athlete_id;

        UPDATE player_wiki_watch SET
          extract   = v_extract,
          team_hint = v_hint,
          prev_team_hint = CASE WHEN v_hint IS DISTINCT FROM v_prev THEN v_prev ELSE prev_team_hint END,
          changed_at = CASE WHEN v_hint IS NOT NULL AND v_prev IS NOT NULL AND v_hint <> v_prev
                            THEN now() ELSE changed_at END,
          change_note = CASE WHEN v_hint IS NOT NULL AND v_prev IS NOT NULL AND v_hint <> v_prev
                             THEN 'team hint: '||v_prev||' → '||v_hint ELSE change_note END,
          updated_at = now()
        WHERE espn_athlete_id = r.espn_athlete_id;

        IF v_hint IS NOT NULL AND v_prev IS NOT NULL AND v_hint <> v_prev THEN
          v_c := v_c + 1;
        END IF;
      END IF;
    END IF;

    UPDATE player_wiki_watch_pending SET resolved_at = now() WHERE id = r.pending_id;
  END LOOP;

  DELETE FROM player_wiki_watch_pending
   WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '6 hours';

  RETURN QUERY SELECT v_p, v_c;
END $$;

COMMENT ON FUNCTION pww_wiki_process() IS
  'Drains player_wiki_watch_pending → player_wiki_watch. Parses the summary extract, '
  'diffs the "for the <team>" hint, and stamps changed_at on a team change. '
  'Mig 20260714130000.';

-- ----------------------------------------------------------------------------
-- (5) Consolidated Trade Watch RPC — per tracked player: roster team/status,
--     Kalshi market leader + candidates, Wikipedia extract + team-change flag,
--     and a fused state ('MOVED' | 'WATCHING'). Email-gated (@s4kent.com) like
--     the player-page RPCs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_trade_watch()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_email text;
  v_players jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.lead_pct DESC NULLS LAST), '[]'::jsonb)
  INTO v_players FROM (
    SELECT
      m.espn_athlete_id,
      m.espn_league,
      m.athlete_name,
      a.headshot_url,
      a.status                                   AS roster_status,
      coalesce(tc.display_name, a.espn_team_id)  AS roster_team,
      (SELECT jsonb_build_object(
                'team', c.dest_team_name, 'performer_id', c.dest_performer_id,
                'pct', round(c.yes_price*100)::int, 'url', c.url)
         FROM player_prediction_markets c
         WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league
           AND c.yes_price IS NOT NULL AND coalesce(c.status,'') NOT IN ('closed','settled','inactive')
         ORDER BY c.yes_price DESC NULLS LAST LIMIT 1)              AS market_leader,
      (SELECT max(c.yes_price*100)
         FROM player_prediction_markets c
         WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league
           AND c.yes_price IS NOT NULL AND coalesce(c.status,'') NOT IN ('closed','settled','inactive')) AS lead_pct,
      (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'team', c.dest_team_name, 'performer_id', c.dest_performer_id,
                'pct', round(c.yes_price*100)::int) ORDER BY c.yes_price DESC NULLS LAST), '[]'::jsonb)
         FROM player_prediction_markets c
         WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league
           AND c.yes_price IS NOT NULL AND coalesce(c.status,'') NOT IN ('closed','settled','inactive')) AS candidates,
      (SELECT max(close_time) FROM player_prediction_markets c
         WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league) AS close_time,
      w.extract        AS wiki_extract,
      w.team_hint      AS wiki_team,
      w.changed_at     AS wiki_changed_at,
      w.last_checked_at AS wiki_checked_at,
      -- fused state: MOVED when the market is near-certain, any leg settled, or
      -- Wikipedia just flagged a team change; else WATCHING.
      CASE
        WHEN (SELECT max(c.yes_price) FROM player_prediction_markets c
                WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league) >= 0.90
          OR EXISTS (SELECT 1 FROM player_prediction_markets c
                      WHERE c.espn_athlete_id = m.espn_athlete_id AND c.espn_league = m.espn_league
                        AND coalesce(c.status,'') IN ('settled','closed'))
          OR (w.changed_at IS NOT NULL AND w.changed_at > now() - interval '7 days')
        THEN 'MOVED' ELSE 'WATCHING'
      END AS state
    FROM player_market_athlete_map m
    LEFT JOIN espn_athletes a
      ON a.espn_athlete_id = m.espn_athlete_id AND a.espn_league = m.espn_league
    LEFT JOIN espn_teams_canonical tc
      ON tc.espn_team_id = a.espn_team_id AND tc.espn_league = m.espn_league
    LEFT JOIN player_wiki_watch w ON w.espn_athlete_id = m.espn_athlete_id
    WHERE m.enabled
  ) p;

  RETURN jsonb_build_object(
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'players', coalesce(v_players, '[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_trade_watch() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_trade_watch() TO authenticated, service_role;
COMMENT ON FUNCTION public.get_trade_watch() IS
  'Consolidated Trade Watch: per tracked player, roster team/status + Kalshi market '
  'leader/candidates + Wikipedia extract/team-change + a fused MOVED/WATCHING state. '
  'Email-gated (@s4kent.com). Mig 20260714130000.';

-- ----------------------------------------------------------------------------
-- (6) Crons — high-frequency (every 5 min, offset marks avoiding :00/:02/:05/:07
--     clusters). Only the tracked-player set is polled, so the volume is tiny.
-- ----------------------------------------------------------------------------
SELECT cron.schedule('pww_wiki_queue_5min',   '3-59/5 * * * *', $$ SELECT public.pww_wiki_queue(); $$);
SELECT cron.schedule('pww_wiki_process_5min',  '6-59/5 * * * *', $$ SELECT public.pww_wiki_process(); $$);

-- ----------------------------------------------------------------------------
-- (7) Kick off the first poll on apply.
-- ----------------------------------------------------------------------------
SELECT public.pww_wiki_queue(interval '0 seconds');
