-- Auto-link TEvo events to ESPN events when both sides exist.
-- Applied to prod 2026-05-08 ~22:00 UTC (this file captures it for git parity).
--
-- Why: today /api/broker/event/{id}/chart-data + /espn require an event_xref
-- row to resolve home/away ESPN team ids. event_xref is mostly populated by
-- hand. As of 2026-05-08, 638 TEvo events have an ESPN-mapped performer but
-- only 80 are linked. Most of the gap is past/future games whose ESPN
-- counterparts haven't been captured yet (espn-collect only pulls events
-- ±24h). This RPC catches matches as ESPN ingest discovers them.
--
-- Match algorithm (high-confidence only):
--   1. TEvo event has primary_performer (or any in performer_ids[]) with
--      performer_external_ids row where source='espn'
--   2. espn_event_snapshots row exists where:
--      - espn_league matches
--      - home_team_id OR away_team_id matches the performer's espn_team_id
--      - parse status_short ('5/8 - 9:30 PM EDT') → M/D matches the
--        TEvo occurs_at_local::date exactly (no proximity fudge — too many
--        false positives across multi-game-per-team-per-week schedules)
--   3. ON CONFLICT (tevo_event_id) DO NOTHING — never overwrite existing.
--
-- Schedule: cron 'auto-link-event-xref-15min' fires every 15 min, 5 min
-- after espn-gameday-10min so its captures are visible. Runs as a SECURITY
-- DEFINER-equivalent via the pg_cron user (uses pg_cron's privilege).

CREATE OR REPLACE FUNCTION auto_link_event_xref()
RETURNS TABLE(linked_count int) LANGUAGE plpgsql AS $$
DECLARE
  v_inserted int;
BEGIN
  WITH espn_perfs AS (
    SELECT performer_id, external_id AS espn_team_id, league
    FROM performer_external_ids WHERE source='espn'
  ),
  unlinked AS (
    SELECT e.id AS tevo_event_id, e.occurs_at_local, ep.espn_team_id, ep.league
    FROM events e
    JOIN espn_perfs ep ON ep.performer_id = e.primary_performer_id OR ep.performer_id = ANY(e.performer_ids)
    WHERE NOT EXISTS (SELECT 1 FROM event_xref ex WHERE ex.tevo_event_id = e.id)
      AND e.occurs_at_local::timestamptz >= NOW() - INTERVAL '14 days'
  ),
  candidates AS (
    SELECT DISTINCT ON (u.tevo_event_id)
      u.tevo_event_id,
      ees.espn_event_id,
      ees.espn_league,
      ees.captured_at
    FROM unlinked u
    JOIN espn_event_snapshots ees
      ON ees.espn_league = u.league
     AND (ees.home_team_id = u.espn_team_id OR ees.away_team_id = u.espn_team_id)
     AND ees.status_short ~ '^\d+/\d+'
     AND make_date(
          EXTRACT(YEAR FROM ees.captured_at)::int,
          split_part(ees.status_short, '/', 1)::int,
          split_part(split_part(ees.status_short, ' ', 1), '/', 2)::int
         ) = (u.occurs_at_local::timestamptz)::date
    ORDER BY u.tevo_event_id, ees.captured_at DESC
  ),
  ins AS (
    INSERT INTO event_xref (tevo_event_id, espn_event_id, espn_league, matched_at, match_method, meta)
    SELECT tevo_event_id, espn_event_id, espn_league, NOW(), 'auto_date_team_v1', '{}'::jsonb
    FROM candidates
    ON CONFLICT (tevo_event_id) DO NOTHING
    RETURNING 1
  )
  SELECT COUNT(*)::int INTO v_inserted FROM ins;

  linked_count := v_inserted;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION auto_link_event_xref() TO authenticated, service_role;

-- Schedule: every 15 minutes (offset to land after espn-gameday-10min).
-- Mirror the existing pg_cron pattern from migration 20260507000021.
SELECT cron.schedule(
  'auto-link-event-xref-15min',
  '5,20,35,50 * * * *',
  $$ SELECT public.auto_link_event_xref(); $$
);
