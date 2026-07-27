-- Master 2-minute cascade — replaces 5 separate freshness crons with one
-- ordered chain. Applied to prod 2026-05-09; this file captures it for git parity.
--
-- Why: user spec — "run all crons as cascading events instead of one at a time.
--   Also run the evo injury and trade chrons every 2 minutes for freshest news."
--   The previous model fired six independent schedules at random offsets, which
--   meant a brand-new event could sit unlinked-to-ESPN for 15 min, then without
--   splits/nonowned medians for another 30 min. The cascade collapses that
--   worst-case staleness from ~50 min to ~2 min.
--
-- Cadence: every 2 minutes. Each tick:
--   Stage 1 (async, fire-and-forget via pg_net):
--     1a. POST espn-collect?scope=roster   → injuries + trades for tracked teams
--     1b. POST espn-collect?scope=gameday  → live game state + last-5 + standings
--   Stage 2 (sync, in dependency order, all in one transaction):
--     2a. auto_link_event_xref()           → new TEvo events get ESPN xref
--     2b. backfill_event_splits_metrics(50)→ min/mode/median split qty per event
--     2c. backfill_event_nonowned_median(50)→ "MARKET NOT US" series
--   Per-stage try/except so one failure does not abort the rest.
--
-- Why ESPN runs async: pg_net.http_post returns a request_id immediately and
--   the HTTP work happens in a background worker. So Stage 1 kicks off and
--   Stage 2 begins immediately in parallel.
--
-- WHY ZONE BACKFILL IS NOT IN THE CASCADE:
--   `backfill_stale_zone_metrics(N)` calls `compute_event_zone_metrics` which
--   uses `match_performer_zone` in a LATERAL join over `listings_snapshots`.
--   That function has been timing out at the cron worker's 120s ceiling for
--   hours pre-cascade (jobid 35 was failing every run before this migration).
--   Forcing it into a 2-min cycle would just turn every cascade tick red.
--   It now runs as its own slower, isolated cron (`zone-backfill-isolated-10min`,
--   batch=5) so a slow zone batch does not block fresh ESPN/splits/nonowned data.
--   Fix-the-cause is a separate NEXT — investigate the lateral-join cost and/or
--   add an index on listings_snapshots(event_id, captured_at, is_ancillary).
--
-- What this REPLACES (unscheduled below):
--   24  espn-roster-10min            (was every 10m, now every 2m via cascade)
--   25  espn-gameday-10min           (was every 10m, now every 2m via cascade)
--   31  auto-link-event-xref-15min   (was 4×/hr, now every 2m)
--   32  compute-event-splits-30min   (was 2×/hr, now every 2m)
--   35  backfill-zone-metrics-10min  (replaced by zone-backfill-isolated-10min)
--   37  compute-event-nonowned-30min (was 2×/hr, now every 2m)
--
-- What stays separate (different concern or by-design tiered):
--   1-5  collect-listings-* tiers     — event-proximity tiered, 20m..24h cadence
--   26   espn-team-daily              — daily, slower scope (rosters, schedule)
--   28   backfill-event-configurations-5min — Tevo seat-map crawl, separate budget
--   30   crawl-venues-and-performers-3min   — discovery loop, not freshness
--   33   crawl-espn-team-assets-3min        — logo crawl, idempotent
--   34   ensure-watchlist-coverage-daily    — daily league sweep
--   36   midnight-catchup-sweep             — daily safety net for missed ticks
--   39   zone-backfill-isolated-10min       — split out from cascade due to 120s timeout bug
--
-- If the cascade itself ever drifts (>2m runtime), midnight-catchup-sweep covers
-- the gap so no event goes >24h without a backfill.

BEGIN;

-- 1. Drop the 6 individual schedules being collapsed into the cascade.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT jobname FROM cron.job WHERE jobname IN (
    'espn-roster-10min',
    'espn-gameday-10min',
    'auto-link-event-xref-15min',
    'compute-event-splits-30min',
    'backfill-zone-metrics-10min',
    'compute-event-nonowned-30min'
  ) LOOP
    PERFORM cron.unschedule(r.jobname);
    RAISE NOTICE 'unscheduled %', r.jobname;
  END LOOP;
END $$;

-- 2. Master cascade function. Per-stage try/except keeps failures isolated.
CREATE OR REPLACE FUNCTION public.master_cascade_2min()
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  result jsonb := '{}'::jsonb;
  t_start timestamptz := clock_timestamp();
  espn_roster_id bigint;
  espn_gameday_id bigint;
  v_linked int;
  v_splits int;
  v_nonowned int;
BEGIN
  -- Stage 1: kick off ESPN ingest (async, fire-and-forget via pg_net)
  BEGIN
    SELECT net.http_post(
      url     := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=roster',
      headers := jsonb_build_object('Content-Type','application/json','X-Cron-Secret','pick-any-random-string-and-save-it'),
      body    := '{}'::jsonb,
      timeout_milliseconds := 90000
    ) INTO espn_roster_id;
    result := result || jsonb_build_object('espn_roster_request_id', espn_roster_id);
  EXCEPTION WHEN OTHERS THEN
    result := result || jsonb_build_object('espn_roster_error', SQLERRM);
  END;

  BEGIN
    SELECT net.http_post(
      url     := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=gameday',
      headers := jsonb_build_object('Content-Type','application/json','X-Cron-Secret','pick-any-random-string-and-save-it'),
      body    := '{}'::jsonb,
      timeout_milliseconds := 90000
    ) INTO espn_gameday_id;
    result := result || jsonb_build_object('espn_gameday_request_id', espn_gameday_id);
  EXCEPTION WHEN OTHERS THEN
    result := result || jsonb_build_object('espn_gameday_error', SQLERRM);
  END;

  -- Stage 2a: auto-link xref (cheap, every tick)
  BEGIN
    SELECT linked_count INTO v_linked FROM public.auto_link_event_xref();
    result := result || jsonb_build_object('auto_link_count', COALESCE(v_linked, 0));
  EXCEPTION WHEN OTHERS THEN
    result := result || jsonb_build_object('auto_link_error', SQLERRM);
  END;

  -- Stage 2b: splits (50/tick × 30 ticks/hr = 1500/hr, was 1000/hr pre-cascade)
  BEGIN
    SELECT updated_count INTO v_splits FROM public.backfill_event_splits_metrics(50);
    result := result || jsonb_build_object('splits_count', COALESCE(v_splits, 0));
  EXCEPTION WHEN OTHERS THEN
    result := result || jsonb_build_object('splits_error', SQLERRM);
  END;

  -- Stage 2c: nonowned median ("MARKET NOT US" series, 50/tick × 30 ticks/hr)
  BEGIN
    SELECT updated_count INTO v_nonowned FROM public.backfill_event_nonowned_median(50);
    result := result || jsonb_build_object('nonowned_count', COALESCE(v_nonowned, 0));
  EXCEPTION WHEN OTHERS THEN
    result := result || jsonb_build_object('nonowned_error', SQLERRM);
  END;

  result := result || jsonb_build_object(
    'started_at',  t_start,
    'duration_ms', round(extract(epoch from clock_timestamp() - t_start) * 1000)
  );

  RETURN result;
END $fn$;

GRANT EXECUTE ON FUNCTION public.master_cascade_2min() TO service_role;

-- 2.5 Side-effect: fix pre-existing bug in auto_link_event_xref. The function
--     was inserting into event_xref without populating `espn_slug` (NOT NULL),
--     so jobid 31's runs were silently failing. Cascade caught it via the
--     per-stage error handler. Adding a CASE mapping for the 7 leagues unblocks
--     auto-linking. NEXT: replace with a proper league_slug lookup table.
CREATE OR REPLACE FUNCTION public.auto_link_event_xref()
RETURNS TABLE(linked_count integer)
LANGUAGE plpgsql
AS $auto_link$
DECLARE
  v_inserted int;
BEGIN
  WITH espn_perfs AS (
    SELECT performer_id, external_id AS espn_team_id, league
    FROM performer_external_ids WHERE source='espn'
  ),
  unlinked AS (
    SELECT e.id AS tevo_event_id, e.occurs_at_local, ep.espn_team_id, ep.league,
           e.primary_performer_id
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
    INSERT INTO event_xref (tevo_event_id, espn_event_id, espn_league, espn_slug, matched_at, match_method, meta)
    SELECT
      tevo_event_id, espn_event_id, espn_league,
      CASE espn_league
        WHEN 'NBA'  THEN 'basketball/nba'
        WHEN 'WNBA' THEN 'basketball/wnba'
        WHEN 'MLB'  THEN 'baseball/mlb'
        WHEN 'NHL'  THEN 'hockey/nhl'
        WHEN 'NFL'  THEN 'football/nfl'
        WHEN 'MLS'  THEN 'soccer/usa.1'
        ELSE 'unknown/' || lower(COALESCE(espn_league, 'unknown'))
      END AS espn_slug,
      NOW(), 'auto_date_team_v1', '{}'::jsonb
    FROM candidates
    ON CONFLICT (tevo_event_id) DO NOTHING
    RETURNING 1
  )
  SELECT COUNT(*)::int INTO v_inserted FROM ins;
  linked_count := v_inserted;
  RETURN NEXT;
END $auto_link$;

-- 3. Schedule the master cascade at */2.
SELECT cron.schedule(
  'master-cascade-2min',
  '*/2 * * * *',
  $cron$ SELECT public.master_cascade_2min(); $cron$
);

-- 4. Re-create zone backfill isolated from cascade. batch=5 instead of 50
--    because match_performer_zone is slow; cron's 120s ceiling means batch=50
--    has been failing every run pre-cascade. 5 events/10 min = 30/hr (down
--    from former target of 300/hr) — midnight-catchup-sweep absorbs the rest.
SELECT cron.schedule(
  'zone-backfill-isolated-10min',
  '4-59/10 * * * *',
  $cron$ SELECT public.backfill_stale_zone_metrics(5); $cron$
);

COMMIT;
