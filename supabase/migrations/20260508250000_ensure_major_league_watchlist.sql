-- Auto-add every ESPN-mapped major-league team + home venue to the watchlist.
-- Applied to prod 2026-05-08 ~23:50 UTC; this file captures it for git parity.
--
-- Why: user spec — "start tracking all NFL/NBA/NHL/MLB/MLS/WNBA performer
-- related events and their venues and all events in those, and auto add
-- future ones." Pre-fn watchlist had 48 performers (mostly NFL) + 0 venues.
-- The first run added 135 performers + 145 venues for total 183 + 145 = 328
-- watch entries → cascades through collect-listings → all events for all
-- big-6 league teams now actively collected.
--
-- The fn is also scheduled daily at 06:00 UTC so when new ESPN teams get
-- added (expansion teams, new MLS clubs, etc.) they auto-flow into the
-- watchlist on the next cron tick. Idempotent — NOT EXISTS guards.

CREATE OR REPLACE FUNCTION ensure_major_league_watchlist_coverage()
RETURNS TABLE(performers_added int, venues_added int) LANGUAGE plpgsql AS $$
DECLARE
  v_p int := 0; v_v int := 0;
BEGIN
  WITH ins AS (
    INSERT INTO watchlist (kind, ext_id, label)
    SELECT 'performer', pei.performer_id, COALESCE(pm.name, 'Performer #' || pei.performer_id::text)
    FROM performer_external_ids pei
    LEFT JOIN performer_metadata pm ON pm.performer_id = pei.performer_id
    WHERE pei.source = 'espn'
      AND pei.league IN ('NFL','NBA','NHL','MLB','MLS','WNBA')
      AND NOT EXISTS (SELECT 1 FROM watchlist w WHERE w.kind='performer' AND w.ext_id = pei.performer_id)
    RETURNING 1
  ) SELECT COUNT(*) INTO v_p FROM ins;

  WITH ins AS (
    INSERT INTO watchlist (kind, ext_id, label)
    SELECT DISTINCT 'venue', phv.venue_id, phv.venue_name
    FROM performer_home_venues phv
    WHERE phv.league IN ('NFL','NBA','NHL','MLB','MLS','WNBA')
      AND phv.venue_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM watchlist w WHERE w.kind='venue' AND w.ext_id = phv.venue_id)
    RETURNING 1
  ) SELECT COUNT(*) INTO v_v FROM ins;

  performers_added := v_p;
  venues_added := v_v;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION ensure_major_league_watchlist_coverage() TO authenticated, service_role;

SELECT cron.schedule(
  'ensure-watchlist-coverage-daily',
  '0 6 * * *',
  $$ SELECT public.ensure_major_league_watchlist_coverage(); $$
);
