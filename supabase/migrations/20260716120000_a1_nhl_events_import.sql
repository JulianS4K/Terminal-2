-- ============================================================================
-- Migration 20260716120000 — NHL 2026-27 event import: game-classify + preseason
--                            matcher fix (unblock the ESPN cross-reference)
--
-- Lane:     A1 data plane (ingest/classification + the in-DB ESPN matcher).
-- Touches:  classify_sports_team_game_events()  (NEW fn) + one backfill run
--           match_events_to_espn_tick()          (CREATE OR REPLACE — prefix strip)
--           cron.schedule('classify-sports-game-events-daily')  (NEW)
--           events.event_type (W/UPDATE, NULL→'game' only), event_xref (via matcher)
-- Reads:    performer_external_ids (espn), performer_espn_team_xref,
--           performer_metadata, espn_event_date_lookup
-- Pre-reqs: 20260508013000 (event_type + the ESPN-team→'game' taxonomy this reuses)
--           20260708131000 (current match_events_to_espn_tick — this supersedes it)
--
-- WHY.  The NHL 2026-27 schedule is in: TEvo is listing the preseason + regular
-- season (~100 future NHL events already collected via the watchlist) and ESPN's
-- scoreboard for hockey/nhl is loaded (Sept preseason + early Oct, ~97 future
-- rows in espn_event_date_lookup). Yet ZERO future NHL events were cross-
-- referenced to ESPN. Two independent blockers, both fixed here:
--
--   (1) event_type was NULL on most freshly-listed NHL events. events.event_type
--       is only set (a) by the one-time backfill in 20260508013000, run in May,
--       or (b) by the venue-crawler (crawl-venues-and-performers), which rotates
--       slowly and hadn't reached the 2026-27 events. match_events_to_espn_tick
--       filters `WHERE event_type='game'`, so NULL-typed games are invisible to
--       it. Fix: classify_sports_team_game_events() — a *recurring, game-only*
--       promoter that reuses the exact ESPN-team→'game' rule from 20260508013000
--       but ONLY fills NULL→'game' for known sports teams (never the ELSE
--       'concert' default), so it is safe to run daily and self-heals every
--       league as each season's schedule drops. Backfilled once inline.
--
--   (2) Preseason events are named "NHL Preseason - Away at Home". The matcher
--       parses the away team via split_part(name,' at ',1) → it got
--       "NHL Preseason - Away", which never matches a performer name. Fix: strip
--       a leading "<LEAGUE> Preseason - " prefix before the split. The strip is a
--       no-op for un-prefixed names, so every existing (regular-season) match is
--       preserved; regular NHL "Away at Home (Home Opener)" already parsed fine.
--
-- Validated on prod (read-only dry-run): with both fixes, 68 of 76 in-window
-- future NHL events resolve to an espn_event_id (0→68); the rest are far-Oct
-- games just beyond ESPN's current +90d pull (land as the window advances) or a
-- one-off TEvo name typo. e.g. "NHL Preseason - Winnipeg Jets at Edmonton Oilers"
-- → espn_event_id 401878099.
--
-- Idempotent: fn is CREATE OR REPLACE; classify fills NULLs only; matcher upserts
-- ON CONFLICT (tevo_event_id); cron.schedule replaces a same-named job.
--
-- ROLLBACK: DROP FUNCTION classify_sports_team_game_events();
--           SELECT cron.unschedule('classify-sports-game-events-daily');
--           (restore match_events_to_espn_tick from 20260708131000 to revert the
--           prefix strip; the event_type='game' promotions are correct data and
--           need no rollback.)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Recurring, game-only classifier. Promotes event_type NULL→'game' for any
--     event whose primary performer (or a co-performer) is an ESPN-mapped team
--     in a game league. Same rule as 20260508013000's CASE, minus the non-game
--     defaults — so it is safe to run on a schedule (only ever labels real games,
--     leaving other NULLs for the venue-crawler to categorize).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION classify_sports_team_game_events()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_updated int;
BEGIN
  WITH upd AS (
    UPDATE events e
    SET event_type = 'game'
    WHERE e.event_type IS NULL
      AND EXISTS (
        SELECT 1 FROM performer_external_ids pei
        WHERE pei.source = 'espn'
          AND pei.league IN ('NBA','WNBA','NFL','MLB','NHL','MLS','NWSL',
                             'CFL','NCAAF','NCAAM','World Cup')
          AND (pei.performer_id = e.primary_performer_id
               OR pei.performer_id = ANY(COALESCE(e.performer_ids, ARRAY[]::integer[])))
      )
    RETURNING 1
  )
  SELECT count(*) INTO v_updated FROM upd;
  RETURN v_updated;
END $$;

COMMENT ON FUNCTION classify_sports_team_game_events() IS
  'Promotes events.event_type NULL->game for events tied to an ESPN-mapped sports '
  'team (reuses the 20260508013000 taxonomy, game-only). Recurring + safe: only '
  'fills NULLs, only labels real games. Unblocks match_events_to_espn_tick, which '
  'filters event_type=game. Added 2026-07-08 wiring covers NWSL/CFL/NCAAF too.';

GRANT EXECUTE ON FUNCTION classify_sports_team_game_events() TO authenticated, service_role;

-- Backfill now (immediate value on apply — lights up the NHL 2026-27 events).
SELECT classify_sports_team_game_events();

-- Daily promote of any newly-listed game events (06:15 — after the 06:00
-- ensure-watchlist-coverage tick; :15 avoids the saturated :00/:02/:05 minutes).
SELECT cron.schedule(
  'classify-sports-game-events-daily',
  '15 6 * * *',
  $$ SELECT public.classify_sports_team_game_events(); $$
);

-- ----------------------------------------------------------------------------
-- (2) Matcher: strip a leading "<LEAGUE> Preseason - " prefix before parsing the
--     away team. Supersedes 20260708131000; only the away_name_raw expression
--     changes — everything else (league set, guards, espn_slug CASE, upsert) is
--     verbatim so existing matches are unaffected.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION match_events_to_espn_tick(p_limit int DEFAULT 10)
RETURNS TABLE(considered int, matched int, no_data int, skipped int)
LANGUAGE plpgsql AS $$
DECLARE
  e RECORD; m RECORD;
  v_considered int := 0; v_matched int := 0; v_no_data int := 0; v_skipped int := 0;
  v_home_team text; v_home_league text; v_away_perf_id bigint; v_away_team text; v_away_league text;
BEGIN
  FOR e IN
    SELECT ev.id, ev.name, ev.occurs_at_local, ev.primary_performer_id,
           -- Strip a leading "<LEAGUE> Preseason - " prefix (e.g.
           -- "NHL Preseason - Winnipeg Jets at Edmonton Oilers") so the away-team
           -- split resolves to a real performer name. No-op for un-prefixed names.
           trim(split_part(
             regexp_replace(ev.name,
               '^(NHL|NBA|NFL|MLB|WNBA|MLS|NWSL|CFL|NCAAF|NCAAM)\s+Preseason\s*-\s*',
               '', 'i'),
             ' at ', 1)) AS away_name_raw,
           ev.occurs_at_local::date AS event_date
    FROM events ev
    WHERE ev.event_type = 'game'
      AND ev.primary_performer_id IS NOT NULL
      AND ev.name ILIKE '% at %'
      AND ev.occurs_at_local::timestamptz BETWEEN now() - interval '7 days'
                                              AND now() + interval '90 days'
      AND NOT EXISTS (SELECT 1 FROM event_xref ex
                       WHERE ex.tevo_event_id = ev.id
                         AND ex.match_method LIKE 'in_db_strict_v%')
    ORDER BY ev.occurs_at_local
    LIMIT p_limit
  LOOP
    v_considered := v_considered + 1;

    SELECT espn_team_id, espn_league INTO v_home_team, v_home_league
    FROM performer_espn_team_xref WHERE tevo_performer_id = e.primary_performer_id LIMIT 1;
    IF v_home_team IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT pm.performer_id INTO v_away_perf_id FROM performer_metadata pm
    WHERE lower(trim(pm.name)) = lower(trim(e.away_name_raw)) LIMIT 1;
    IF v_away_perf_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT espn_team_id, espn_league INTO v_away_team, v_away_league
    FROM performer_espn_team_xref WHERE tevo_performer_id = v_away_perf_id AND espn_league = v_home_league LIMIT 1;
    IF v_away_team IS NULL OR v_away_league <> v_home_league THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT * INTO m FROM espn_event_date_lookup edl
    WHERE edl.espn_league = v_home_league
      AND edl.home_team_id = v_home_team
      AND edl.away_team_id = v_away_team
      AND (edl.game_at_utc AT TIME ZONE 'America/Los_Angeles')::date = e.event_date
    LIMIT 1;
    IF NOT FOUND THEN v_no_data := v_no_data + 1; CONTINUE; END IF;

    INSERT INTO event_xref(tevo_event_id, espn_event_id, espn_league, espn_slug,
                           match_method, meta, matched_at)
    VALUES (e.id, m.espn_event_id, m.espn_league,
      CASE m.espn_league
        WHEN 'NBA' THEN 'basketball/nba' WHEN 'NFL' THEN 'football/nfl'
        WHEN 'MLB' THEN 'baseball/mlb'   WHEN 'NHL' THEN 'hockey/nhl'
        WHEN 'WNBA' THEN 'basketball/wnba' WHEN 'MLS' THEN 'soccer/usa.1'
        WHEN 'NWSL' THEN 'soccer/usa.nwsl' WHEN 'CFL' THEN 'football/cfl'
        WHEN 'NCAAF' THEN 'football/college-football' END,
      'in_db_strict_v1',
      jsonb_build_object('home_team_id', v_home_team, 'away_team_id', v_away_team,
                         'event_date', e.event_date, 'tevo_name', e.name,
                         'matched_via', 'in_db_strict_v1_pt_date'),
      now())
    ON CONFLICT (tevo_event_id) DO UPDATE SET
      espn_event_id = EXCLUDED.espn_event_id, espn_league = EXCLUDED.espn_league,
      espn_slug = EXCLUDED.espn_slug, match_method = EXCLUDED.match_method,
      meta = EXCLUDED.meta, matched_at = now();
    v_matched := v_matched + 1;
  END LOOP;
  RETURN QUERY SELECT v_considered, v_matched, v_no_data, v_skipped;
END $$;

-- Immediate sweep so the NHL events cross-reference on apply (bounded; the
-- existing cron from 20260510120000 keeps calling this fn on its schedule).
SELECT * FROM match_events_to_espn_tick(500);
