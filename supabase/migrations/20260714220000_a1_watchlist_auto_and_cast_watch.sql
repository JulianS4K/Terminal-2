-- ============================================================================
-- Migration 20260714220000 — Automated trade pipeline (market → watchlist) +
--                            Cast Watch (Broadway analog of Trade Watch)
--
-- Lane:     A1 data plane
-- Touches:  watchlist_autopopulate (W: new — markets → watchlist),
--           pww_wiki_queue (W: LIMIT so a bigger watchlist doesn't burst wiki),
--           get_cast_watch (W: new — Broadway cast-change RPC),
--           player_watchlist (W: auto-inserts), prediction_markets + espn_athletes
--           (R), broadway_show_ref + broadway_cast_run + broadway_cast_pull_log (R),
--           1 cron.
-- Pre-reqs: 20260714200000 (player_watchlist + pww_wiki_queue),
--           20260702235600 (prediction_markets), 20260703013000 (broadway cast pipeline)
--
-- WHY: (1) operator wants the watchlist AUTO-curated from trade hype so the
--   per-player pollers only track people who actually have market attention —
--   not manually chosen. watchlist_autopopulate() extracts the subject athlete
--   from every active player-movement market (Kalshi/Polymarket "Next Team",
--   "be traded", "to sign") and adds the resolved athletes to the watchlist.
--   Resolution: full_name / display_name / punctuation-normalized (validated
--   live: 34/36 market names resolved). ON CONFLICT DO NOTHING respects manual
--   removes. Cron'd daily; run once here.
--   (2) Broadway is the same pattern — "cast change detected" is the Broadway
--   "trade". get_cast_watch() is the Trade Watch twin: per tracked show, current
--   cast + the last Wikipedia cast-section change flag + CHANGED/STABLE state.
--
-- LOAD: the reddit social poll is already a 1/min round-robin (bounded regardless
--   of watchlist size). The wiki queue fired ALL due athletes — now LIMIT 15 per
--   tick (oldest first) so a 30+ watchlist doesn't burst Wikipedia.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Automated trade pipeline: active movement markets → watchlist.
-- ----------------------------------------------------------------------------
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
     AND ( lower(a.full_name)    = lower(n.nm)
        OR lower(a.display_name) = lower(n.nm)
        OR regexp_replace(lower(a.full_name),'[^a-z]','','g')
             = regexp_replace(lower(n.nm),'[^a-z]','','g') )
    WHERE n.nm IS NOT NULL AND length(n.nm) > 3
  )
  INSERT INTO player_watchlist(espn_athlete_id, espn_league, athlete_name, added_by, notes)
  SELECT espn_athlete_id, espn_league, full_name, 'auto:market',
         'auto-added from an active player-movement market'
  FROM resolved
  ON CONFLICT (espn_athlete_id, espn_league) DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  RETURN v_added;
END $$;

COMMENT ON FUNCTION public.watchlist_autopopulate() IS
  'Auto-adds athletes with an active prediction market about their movement '
  '(Next Team / be traded / to sign) to player_watchlist. ON CONFLICT DO NOTHING '
  '(respects manual removes). Mig 20260714220000.';

SELECT cron.schedule('watchlist_autopopulate_daily', '35 8 * * *',
  $$ SELECT public.watchlist_autopopulate(); $$);
SELECT public.watchlist_autopopulate();

-- ----------------------------------------------------------------------------
-- (2) Bound the wiki queue: oldest-15 due per tick (round-robin) so a large
--     watchlist doesn't burst Wikipedia. Body identical to mig 20260714200000
--     plus ORDER BY + LIMIT.
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
           coalesce(aw.wiki_title, w.wiki_title, m.athlete_name) AS title,
           w.last_checked_at
    FROM player_watchlist m
    LEFT JOIN athlete_wikipedia aw ON aw.espn_athlete_id = m.espn_athlete_id
    LEFT JOIN player_wiki_watch  w  ON w.espn_athlete_id  = m.espn_athlete_id
    WHERE m.enabled AND m.poll_wiki
      AND (w.last_checked_at IS NULL OR w.last_checked_at < now() - p_min_age)
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
-- (3) Cast Watch — Broadway analog of Trade Watch. Per tracked show: current
--     cast (recent broadway_cast_run), the last Wikipedia cast-section change
--     flag, and a CHANGED/STABLE state. Email-gated.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_cast_watch()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $func$
DECLARE v_email text; v_shows jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.last_change DESC NULLS LAST, s.title), '[]'::jsonb)
  INTO v_shows FROM (
    SELECT
      r.title, r.show_slug, r.tevo_performer_id, r.tevo_venue_id, r.cast_last_polled_at,
      (SELECT coalesce(jsonb_agg(jsonb_build_object('performer', t.performer_name, 'role', t.role)), '[]'::jsonb)
         FROM (SELECT cr.performer_name, cr.role
                 FROM broadway_cast_run cr
                WHERE cr.show_slug = r.show_slug AND coalesce(cr.performer_name,'') <> ''
                ORDER BY cr.run_start DESC NULLS LAST, cr.last_seen_at DESC NULLS LAST
                LIMIT 6) t) AS leads,
      (SELECT max(pl.created_at) FROM broadway_cast_pull_log pl
         WHERE pl.show_slug = r.show_slug AND (pl.section_changed OR pl.flag_raised)) AS last_change,
      (SELECT count(*) FROM broadway_cast_pull_log pl
         WHERE pl.show_slug = r.show_slug AND (pl.section_changed OR pl.flag_raised)
           AND pl.created_at > now() - interval '30 days') AS change_flags_30d,
      CASE WHEN (SELECT max(pl.created_at) FROM broadway_cast_pull_log pl
                  WHERE pl.show_slug = r.show_slug AND (pl.section_changed OR pl.flag_raised))
                > now() - interval '14 days'
           THEN 'CHANGED' ELSE 'STABLE' END AS state
    FROM broadway_show_ref r
    WHERE r.cast_wiki_title IS NOT NULL OR r.tevo_performer_id IS NOT NULL
  ) s;

  RETURN jsonb_build_object(
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'shows', coalesce(v_shows, '[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_cast_watch() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_cast_watch() TO authenticated, service_role;
COMMENT ON FUNCTION public.get_cast_watch() IS
  'Cast Watch (Broadway twin of get_trade_watch): per tracked show, current cast '
  '+ last Wikipedia cast-section change flag + CHANGED/STABLE state. Email-gated. '
  'Mig 20260714220000.';
