-- ============================================================================
-- Migration 20260622xxxxxx — derive_event_lifecycle: don't ghost actively-traded games
--
-- Lane:     A1 (data plane — owns event lifecycle classification)
-- Touches:  derive_event_lifecycle() (W, CREATE OR REPLACE)
-- Pre-reqs: existing definition (stop_tracking_cancelled_events* migrations)
--
-- WHY: the 'sports_stale_>72hr' rule classified ANY event_type='game' with a
--   future date and events.last_seen older than 72h as 'ghost_eliminated'. That
--   signal is meant for playoff/"if necessary" games that vanish from the feed —
--   but it keys ONLY on events.last_seen, which is refreshed by the EVO
--   events-feed crawl, NOT by the listings collectors. A seeded/actively-traded
--   event (e.g. UFC 329, tevo 3350088) whose last_seen decays gets falsely
--   marked ghost_eliminated even while fresh listings + metrics arrive daily.
--
--   FIX: gate the pure-staleness sports rule on the ABSENCE of fresh market
--   activity. event_metrics within the last 72h proves the event is live, so it
--   stays 'active'. Genuinely-eliminated games stop getting metrics, so they
--   still ghost correctly. event_metrics is indexed by event_id (cheap EXISTS).
--   The ESPN-driven 'home_team_eliminated_no_espn_game' and the explicit
--   'TBD+stale' rules are unchanged (those are deliberate, non-staleness signals).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.derive_event_lifecycle(p_event_id bigint)
 RETURNS TABLE(status text, confidence numeric, reasons text[], is_active boolean, hrs_since_seen numeric, hrs_to_event numeric, ghost_score integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e RECORD;
  espn RECORD;
  v_reasons text[] := ARRAY[]::text[];
  v_status text;
  v_conf numeric := 0.5;
  v_active boolean := true;
  v_score int := 0;
  v_now timestamptz := NOW();
  v_fresh_market boolean := false;
BEGIN
  SELECT id, name, occurs_at_local, state, last_seen, event_type, primary_performer_name, primary_performer_id
  INTO e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN
    status := 'unknown'; confidence := 0; reasons := ARRAY['event_not_found'];
    is_active := false; ghost_score := 0;
    RETURN NEXT; RETURN;
  END IF;

  hrs_since_seen := EXTRACT(EPOCH FROM (v_now - e.last_seen)) / 3600.0;
  hrs_to_event   := EXTRACT(EPOCH FROM (e.occurs_at_local::timestamptz - v_now)) / 3600.0;

  -- Live market activity proves the event is real/active regardless of how
  -- stale events.last_seen is (which only tracks the EVO events-feed crawl).
  SELECT EXISTS (
    SELECT 1 FROM event_metrics em
    WHERE em.event_id = p_event_id AND em.captured_at > v_now - interval '72 hours'
  ) INTO v_fresh_market;

  SELECT ees.state, ees.status_short, ees.home_score, ees.away_score
  INTO espn
  FROM event_xref ex
  LEFT JOIN LATERAL (
    SELECT state, status_short, home_score, away_score
    FROM espn_event_snapshots WHERE espn_event_id = ex.espn_event_id
    ORDER BY captured_at DESC LIMIT 1
  ) ees ON true
  WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  IF e.state IN ('cancelled', 'ignored') THEN
    status := 'cancelled'; v_active := false; v_conf := 0.95;
    v_reasons := array_append(v_reasons, format('tevo_state=%s', e.state));
  ELSIF e.state = 'rescheduled' THEN
    status := 'postponed'; v_active := false; v_conf := 0.9;
    v_reasons := array_append(v_reasons, 'tevo_state=rescheduled');
  ELSIF espn.state = 'post' AND espn.home_score IS NOT NULL THEN
    status := 'completed'; v_active := false; v_conf := 0.95;
    v_reasons := array_append(v_reasons, format('espn_post_score=%s-%s', espn.home_score, espn.away_score));
  ELSIF hrs_to_event < -6 THEN
    status := 'completed'; v_active := false; v_conf := 0.85;
    v_reasons := array_append(v_reasons, format('past_event_%shr', round(hrs_to_event::numeric, 1)));
  ELSIF espn.status_short IS NOT NULL AND (
        espn.status_short ILIKE '%postpon%' OR espn.status_short ILIKE '%PPD%'
        OR espn.status_short ILIKE '%cancel%') THEN
    status := 'postponed'; v_active := false; v_conf := 0.9;
    v_reasons := array_append(v_reasons, format('espn_status=%s', espn.status_short));
  ELSIF e.event_type = 'game' AND hrs_to_event > 0 AND e.primary_performer_id IS NOT NULL
    AND e.name ~* '(finals|playoff|conference|round [0-9]|if necessary|game [0-9])'
    AND EXISTS (
      SELECT 1 FROM performer_espn_team_xref x
      WHERE x.tevo_performer_id = e.primary_performer_id
        AND EXISTS (SELECT 1 FROM espn_event_date_lookup l
          WHERE l.espn_league = x.espn_league
            AND (l.home_team_id = x.espn_team_id OR l.away_team_id = x.espn_team_id)
            AND l.game_at_utc BETWEEN v_now - interval '21 days' AND v_now)
        AND EXISTS (SELECT 1 FROM espn_event_date_lookup l
          WHERE l.espn_league = x.espn_league
            AND l.game_at_utc > v_now
            AND l.game_at_utc < e.occurs_at_local::timestamptz + interval '10 days')
        AND NOT EXISTS (SELECT 1 FROM espn_event_date_lookup l
          WHERE l.espn_league = x.espn_league
            AND (l.home_team_id = x.espn_team_id OR l.away_team_id = x.espn_team_id)
            AND l.game_at_utc > v_now
            AND l.game_at_utc < e.occurs_at_local::timestamptz + interval '10 days')
    ) THEN
    status := 'ghost_eliminated'; v_active := false; v_conf := 0.9;
    v_score := v_score + 4;
    v_reasons := array_append(v_reasons, 'home_team_eliminated_no_espn_game');
  ELSIF e.event_type = 'game' AND e.name ILIKE '%TBD%' AND hrs_since_seen > 48 THEN
    status := 'ghost_eliminated'; v_active := false; v_conf := 0.95;
    v_score := v_score + 5;
    v_reasons := array_append(v_reasons, format('tbd_in_name+stale_%shr', round(hrs_since_seen::numeric, 0)));
  ELSIF e.event_type = 'game' AND hrs_since_seen > 72 AND hrs_to_event > 0 AND NOT v_fresh_market THEN
    status := 'ghost_eliminated'; v_active := false; v_conf := 0.75;
    v_score := v_score + 3;
    v_reasons := array_append(v_reasons, format('sports_stale_%shr_no_market', round(hrs_since_seen::numeric, 0)));
  ELSE
    status := 'active'; v_active := true; v_conf := 0.9;
    IF v_fresh_market AND hrs_since_seen > 72 THEN
      -- last_seen is stale but the market is live (e.g. seeded event not re-crawled)
      v_reasons := array_append(v_reasons, format('active_market_72h+last_seen_stale_%shr', round(hrs_since_seen::numeric, 0)));
    ELSIF hrs_since_seen <= 24 THEN
      v_reasons := array_append(v_reasons, format('fresh_%shr', round(hrs_since_seen::numeric, 1)));
    ELSE
      v_reasons := array_append(v_reasons, format('warm_%shr', round(hrs_since_seen::numeric, 1)));
      v_conf := 0.7;
    END IF;
  END IF;

  reasons     := v_reasons;
  confidence  := v_conf;
  is_active   := v_active;
  ghost_score := v_score;
  RETURN NEXT;
END $function$;
