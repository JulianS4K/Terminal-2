-- ============================================================================
-- Migration 20260709131500 — daily listings poll of major-league season-ticket events
--
-- Lane:     A1 (data plane / ingest)
-- Touches:  stpv_poll_season_ticket_events(int) (fn, new; service-only),
--           evo_listings_poll_state (W, via the same upsert the poll tick uses),
--           cron.job (W: stpv_poll_daily), cron_policy (W),
--           events (R), performer_espn_team_xref (R)
-- Pre-reqs: 20260709130000 (season-ticket value engine this feeds),
--           public._cron_invoke_edge_fn(text,jsonb), public.evo_listings_poll_state,
--           public.cron_should_fire(text), the collect-listings edge fn
--
-- WHY: the EVO listings poll (evo_listings_poll_tick / evo_listings_poll_2min)
-- cadences by hours-to-event via collector_band — so a season-ticket PACKAGE event
-- (placeholder date, effectively far-future) polls infrequently and its listings
-- go stale between leaderboard rebuilds. This guarantees each major-league season-
-- ticket package event gets a listings poll once daily, right before the 09:40
-- season_ticket_package_value refresh, so the leaderboard rebuilds on fresh asks.
--
-- Mirrors the poll tick exactly (same collect-listings?event_id= edge-fn call +
-- evo_listings_poll_state upsert) — it does NOT change any event's normal cadence,
-- only adds a guaranteed daily poll for this small (~one per team per league) set.
-- Home games keep their standard distance-based cadence.
--
-- Already applied to prod · via MCP 2026-07-09 (idempotent; re-apply is a no-op).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.stpv_poll_season_ticket_events(
  p_max int DEFAULT 60
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  r   record;
  v_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: stpv_poll_season_ticket_events is service-only' USING ERRCODE = '42501';
  END IF;

  FOR r IN
    SELECT e.id
    FROM public.events e
    JOIN public.performer_espn_team_xref x ON x.tevo_performer_id = e.primary_performer_id
    LEFT JOIN public.evo_listings_poll_state ps ON ps.event_id = e.id
    WHERE e.name ~* 'season ticket' AND e.name !~* 'parking'
      AND e.event_type = 'game' AND e.venue_id IS NOT NULL AND e.state = 'shown'
      AND x.espn_league IN ('NFL', 'NBA', 'MLB', 'NHL', 'MLS')       -- STPV_MAJOR_LEAGUES
    ORDER BY ps.last_polled_listings_at ASC NULLS FIRST              -- stalest first
    LIMIT p_max
  LOOP
    -- Same enqueue + state upsert the poll tick uses (async net.http_post).
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id=' || r.id::text,
      '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state(event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.id, now(), 1, current_date)
      ON CONFLICT (event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$fn$;

REVOKE ALL ON FUNCTION public.stpv_poll_season_ticket_events(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.stpv_poll_season_ticket_events(int) TO service_role;

-- Daily at 09:08 UTC — before the 09:40 season_ticket_package_value refresh, with
-- ~30 min for the async pulls to land. Off the :00/:02/:05/:07 saturated marks.
SELECT cron.schedule(
  'stpv_poll_daily',
  '8 9 * * *',
  $cron$BEGIN; SET LOCAL statement_timeout='120s'; DO $b$ BEGIN
    IF NOT public.cron_should_fire('stpv_poll_daily') THEN RETURN; END IF;
    PERFORM public.stpv_poll_season_ticket_events(60);
  END $b$; COMMIT;$cron$
);

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, work_check_sql, enabled, notes)
VALUES ('stpv_poll_daily', ARRAY[]::int[], 1440, 1440, 1, 'SELECT true', true,
  'Daily pre-refresh listings poll of major-league season-ticket package events (feeds season_ticket_package_value)')
ON CONFLICT (jobname) DO UPDATE
  SET enabled = true, notes = EXCLUDED.notes, updated_at = now();
