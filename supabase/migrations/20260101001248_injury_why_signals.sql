-- Migration 20260703220000 · level:data-collection · lane:a1 · writes:why_signals · reads:events,performer_metadata,espn_injuries_snapshots · pre:20260508017000
-- Injury -> "meaning" (why_signals): emit per-event injury_status demand signals from
-- ESPN injuries. OUT / IL / suspension = heavier demand drag; day-to-day / questionable
-- = light. Count-based (not yet star-weighted — a v2 would weight by player popularity).
-- Idempotent refresh (DELETE own rows + re-INSERT); rows expire in 2 days so a stale
-- feed self-clears. Reads espn_injuries_snapshots (NFL/NBA/WNBA/MLB/NHL — no soccer).

CREATE OR REPLACE FUNCTION refresh_injury_why_signals() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  DELETE FROM why_signals WHERE signal_kind = 'injury_status' AND source = 'espn';

  WITH up AS (
    SELECT e.id AS event_id, pm.espn_team_id, pm.name AS team
    FROM events e
    JOIN performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE pm.espn_team_id IS NOT NULL
      AND e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '60 days'
  ),
  latest_inj AS (
    SELECT DISTINCT ON (i.espn_team_id, i.athlete_id)
           i.espn_team_id, i.athlete_id, lower(i.status) AS status
    FROM espn_injuries_snapshots i
    WHERE i.captured_at > now() - interval '7 days'
    ORDER BY i.espn_team_id, i.athlete_id, i.captured_at DESC
  ),
  agg AS (
    SELECT up.event_id, up.team,
      -- near-term unavailable only; EXCLUDE 60-day-IL (season-long, already priced, not news)
      count(*) FILTER (WHERE li.status IN ('out','injured reserve','suspension','10-day-il','15-day-il','7-day il')) AS out_ct,
      count(*) FILTER (WHERE li.status IN ('day-to-day','questionable','doubtful')) AS q_ct
    FROM up JOIN latest_inj li ON li.espn_team_id = up.espn_team_id
    GROUP BY up.event_id, up.team
  )
  INSERT INTO why_signals(scope, scope_id, scope_label, signal_kind, signal_value,
                          signal_label, weight, source, expires_at)
  SELECT 'event', event_id, team, 'injury_status',
         greatest(-1.0, -(out_ct * 0.06 + q_ct * 0.02))::numeric,
         out_ct || ' out/IL, ' || q_ct || ' day-to-day (' || team || ')',
         1.0, 'espn', now() + interval '2 days'
  FROM agg
  WHERE out_ct + q_ct > 0;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;
