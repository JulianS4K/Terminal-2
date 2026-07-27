-- Event lifecycle classifier — sort ghost / cancelled / completed events out
-- of "live" surfaces (movers, league grid, portfolio aggregates).
-- Applied to prod 2026-05-09; this file captures it for git parity.
--
-- Why: user reported that Toronto Raptors and Boston Celtics had events
-- showing up as live in the terminal even though those teams were
-- eliminated from the playoffs (so the speculative bracket games will
-- never happen). Audit found 203 such "ghost" future events out of 1134
-- (~18% pollution). Two distinct ghost patterns:
--
--   1. PLAYOFF ELIMINATIONS — name contains "TBD" (placeholder for
--      undecided opponent), event_type='game', and TEvo stopped including
--      the event in its feeds (last_seen >48h ago). 83 events.
--
--   2. DECIDED-SERIES GHOSTS — same as above but the matchup is named
--      explicitly (e.g. "New York Knicks at Boston Celtics (Game 5)" when
--      the Knicks already won the series 4-1). Caught by event_type='game'
--      + last_seen >72h ago. ~120 events.
--
-- Live events are never stale: KNICKS_LIVE sample shows avg 1.0h since
-- last_seen, max 1.1h. GHOST_CANDIDATE sample (Raptors+Celtics future
-- games): avg 133h, min 121h. Zero overlap.
--
-- The classifier returns:
--   status        text   one of: active | ghost_eliminated | completed |
--                          postponed | cancelled | unknown
--   confidence    numeric 0.0-1.0
--   reasons       text[] human-readable why this classification fired
--   is_active     bool   convenience: status='active' (the only "live" bucket)
--   hrs_since_seen numeric staleness signal (NOW - events.last_seen)
--   hrs_to_event   numeric NOW - occurs_at_local
--   ghost_score   int    cumulative ghost evidence (0=clean, 5+=strong ghost)
--
-- Usage:
--   SELECT * FROM derive_event_lifecycle(3341147);
--   -- returns one row with classification
--
-- API integration: app.py's /api/broker/event/{id}/overview adds a
-- `lifecycle` block; movers / league / portfolio endpoints default to
-- excluding non-active events with an `?include_inactive=true` override.

CREATE OR REPLACE FUNCTION public.derive_event_lifecycle(p_event_id bigint)
RETURNS TABLE(
  status text,
  confidence numeric,
  reasons text[],
  is_active boolean,
  hrs_since_seen numeric,
  hrs_to_event numeric,
  ghost_score int
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e RECORD;
  espn RECORD;
  v_reasons text[] := ARRAY[]::text[];
  v_status text;
  v_conf numeric := 0.5;
  v_active boolean := true;
  v_score int := 0;
  v_now timestamptz := NOW();
BEGIN
  SELECT id, name, occurs_at_local, state, last_seen, event_type, primary_performer_name
  INTO e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN
    status := 'unknown'; confidence := 0; reasons := ARRAY['event_not_found'];
    is_active := false; ghost_score := 0;
    RETURN NEXT; RETURN;
  END IF;

  hrs_since_seen := EXTRACT(EPOCH FROM (v_now - e.last_seen)) / 3600.0;
  hrs_to_event   := EXTRACT(EPOCH FROM (e.occurs_at_local::timestamptz - v_now)) / 3600.0;

  -- Latest ESPN snapshot if event_xref exists
  SELECT ees.state, ees.status_short, ees.home_score, ees.away_score
  INTO espn
  FROM event_xref ex
  LEFT JOIN LATERAL (
    SELECT state, status_short, home_score, away_score
    FROM espn_event_snapshots
    WHERE espn_event_id = ex.espn_event_id
    ORDER BY captured_at DESC LIMIT 1
  ) ees ON true
  WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  -- Rule 1: TEvo state explicit
  IF e.state IN ('cancelled', 'ignored') THEN
    status := 'cancelled'; v_active := false; v_conf := 0.95;
    v_reasons := array_append(v_reasons, format('tevo_state=%s', e.state));
  ELSIF e.state = 'rescheduled' THEN
    status := 'postponed'; v_active := false; v_conf := 0.9;
    v_reasons := array_append(v_reasons, 'tevo_state=rescheduled');

  -- Rule 2: ESPN says final + scores → completed
  ELSIF espn.state = 'post' AND espn.home_score IS NOT NULL THEN
    status := 'completed'; v_active := false; v_conf := 0.95;
    v_reasons := array_append(v_reasons, format('espn_post_score=%s-%s', espn.home_score, espn.away_score));

  -- Rule 3: Past start time + 6h grace
  ELSIF hrs_to_event < -6 THEN
    status := 'completed'; v_active := false; v_conf := 0.85;
    v_reasons := array_append(v_reasons, format('past_event_%shr', round(hrs_to_event::numeric, 1)));

  -- Rule 4: ESPN postponed/cancelled status_short
  ELSIF espn.status_short IS NOT NULL AND (
        espn.status_short ILIKE '%postpon%' OR espn.status_short ILIKE '%PPD%'
        OR espn.status_short ILIKE '%cancel%') THEN
    status := 'postponed'; v_active := false; v_conf := 0.9;
    v_reasons := array_append(v_reasons, format('espn_status=%s', espn.status_short));

  -- Rule 5: Ghost playoff (sports + TBD in name + stale TEvo last_seen)
  ELSIF e.event_type = 'game' AND e.name ILIKE '%TBD%' AND hrs_since_seen > 48 THEN
    status := 'ghost_eliminated'; v_active := false; v_conf := 0.95;
    v_score := v_score + 5;
    v_reasons := array_append(v_reasons, format('tbd_in_name+stale_%shr', round(hrs_since_seen::numeric, 0)));

  -- Rule 6: Sports stale-future without TBD (decided-series ghosts: e.g. Game 5
  -- of a series the team already lost 4-1). Lower confidence than Rule 5
  -- because some events legitimately get less crawl attention.
  ELSIF e.event_type = 'game' AND hrs_since_seen > 72 AND hrs_to_event > 0 THEN
    status := 'ghost_eliminated'; v_active := false; v_conf := 0.75;
    v_score := v_score + 3;
    v_reasons := array_append(v_reasons, format('sports_stale_%shr', round(hrs_since_seen::numeric, 0)));

  -- Rule 7: Active event. Confidence drops as last_seen ages out of fresh.
  ELSE
    status := 'active'; v_active := true; v_conf := 0.9;
    IF hrs_since_seen <= 24 THEN
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
END $$;

GRANT EXECUTE ON FUNCTION public.derive_event_lifecycle(bigint) TO authenticated, service_role;

-- Convenience view — bulk classification across all events. The API
-- endpoints that filter for "live" surfaces JOIN against this so they
-- can WHERE is_active=true cheaply.
CREATE OR REPLACE VIEW public.event_lifecycle AS
SELECT e.id AS event_id, lc.status, lc.confidence, lc.is_active,
       lc.hrs_since_seen, lc.hrs_to_event, lc.ghost_score, lc.reasons
FROM events e,
     LATERAL public.derive_event_lifecycle(e.id) lc;

GRANT SELECT ON public.event_lifecycle TO authenticated, service_role;

COMMENT ON FUNCTION public.derive_event_lifecycle(bigint) IS
'Classify an event as active / ghost_eliminated / completed / postponed / cancelled / unknown. Used to sort ghost playoff games (eliminated team brackets) out of broker terminal live surfaces. See migration 20260509050000 for rule definitions.';

COMMENT ON VIEW public.event_lifecycle IS
'Bulk lifecycle classification across all events. Filter is_active=true for live surfaces (movers, league grid, portfolio aggregates). 18% of future events are non-active as of 2026-05-09.';
