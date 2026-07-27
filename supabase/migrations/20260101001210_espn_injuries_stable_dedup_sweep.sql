-- ============================================================================
-- Migration 20260702230500 — espn_injuries_snapshots: churn cleanup + retention
--
-- Lane:     A1 (data plane — ESPN ingest tables + crons)  [operator-routed]
-- Touches:  espn_injuries_snapshots (W: DELETE churn + UPDATE is_baseline),
--           espn_injuries_sweep (W: new fn), cron.job (W: schedule)
-- Pre-reqs: 20260507000013 (espn_injuries_snapshots)
--           20260507000017 (upsert_espn_injury / is_baseline / change-only ingest)
--           20260520220000 (Arias RPC-side fix — this is its deferred Layer-2)
--           espn-collect v8 edge fn (stable dedup key) — same PR
--
-- WHY: ESPN's /sports/{slug}/injuries mints a FRESH PROVISIONAL athlete id per
--   poll when it lacks a real one (verified live 2026-07-02: "Jared Jones" MLB
--   churned -207375→-207361 negative, "Satou Sabally" WNBA churned 43901→43887
--   positive — so it is NOT confined to negative ids or specific leagues as the
--   2026-05-09 note assumed). The old ingest keyed upsert_espn_injury on that id,
--   so `where athlete_id = p_athlete_id` missed the prior row every run and the
--   SAME injury re-inserted as is_baseline=true each 10-min roster pass. Result:
--   38,187 rows / 889 MB for only ~2,431 athletes / ~7,440 real transitions —
--   ~80% churn. It also made `WHERE is_baseline=false` (real-changes-only) filters
--   in broker.py + the chart RPCs return almost nothing for these leagues (the
--   Arias flood, mig 20260520220000, which patched the RPC read side but
--   explicitly deferred this ingest-side fix to "its own scoped PR").
--
--   The edge-fn half (espn-collect v8, same PR) stops NEW churn by keying on
--   stable identity (team_id + slugified athlete_name). This migration cleans the
--   accumulated bloat and installs a retention sweep so any residual/future churn
--   (e.g. before the v8 deploy lands) stays bounded.
--
-- WHAT espn_injuries_sweep() does (idempotent — re-run deletes nothing):
--   (1) COLLAPSE CHURN: within each stable-identity partition (league, team,
--       lower(name)) ordered by capture time, delete any row whose injury-
--       meaningful content (status | injury_type | short_comment | return_date)
--       is identical to its immediate predecessor. This keeps the FIRST row of
--       every distinct-state run — i.e. every genuine transition, including a
--       later re-occurrence of an earlier state — and drops only the per-poll
--       re-inserts. (Dry-run 2026-07-02: 30,747 churn deleted, 7,440 transitions
--       kept. All history preserved.) Same stable-identity key the Arias RPC fix
--       uses: coalesce(athlete_name, athlete_id) scoped by (league, team) —
--       team_id is reused across leagues (PROJECT_BIBLE §3 landmine).
--   (2) FIX is_baseline: the earliest surviving row per stable identity is the
--       baseline (is_baseline=true); every later transition is a real change
--       (is_baseline=false). Only rows whose flag is wrong are updated. This
--       repairs the `is_baseline=false` read filters for the historical rows.
--
-- NOTE (disk): the DELETE removes rows but Postgres does not shrink the heap;
--   ~889 MB of dead tuples remain until VACUUM. Autovacuum will return the space
--   to the free-space map for reuse; to reclaim it to the OS, A1 may run
--   `VACUUM (FULL, ANALYZE) public.espn_injuries_snapshots` out-of-band (takes an
--   ACCESS EXCLUSIVE lock — cannot run inside this migration's transaction).
--
-- Read-only vs upstream: no upstream-API calls (RULE 2 N/A). Prod-data mutation
--   (DELETE/UPDATE) is A1/operator-gated at apply time.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.espn_injuries_sweep()
RETURNS TABLE(churn_deleted bigint, baseline_fixed bigint)
LANGUAGE plpgsql
AS $$
DECLARE
  v_deleted bigint;
  v_fixed   bigint;
BEGIN
  -- (1) Collapse per-poll churn, keeping the first row of every distinct-state
  --     run (the real transitions). content hash EXCLUDES athlete_id (the
  --     churning field) and position (not injury-meaningful).
  WITH ordered AS (
    SELECT id,
      md5(coalesce(status,'')       || '|' || coalesce(injury_type,'')      || '|' ||
          coalesce(short_comment,'') || '|' || coalesce(return_date::text,'')) AS content,
      lag(
        md5(coalesce(status,'')       || '|' || coalesce(injury_type,'')      || '|' ||
            coalesce(short_comment,'') || '|' || coalesce(return_date::text,''))
      ) OVER (
        PARTITION BY espn_league, espn_team_id,
                     lower(btrim(coalesce(athlete_name, athlete_id, '')))
        ORDER BY captured_at, id
      ) AS prev_content
    FROM public.espn_injuries_snapshots
  )
  DELETE FROM public.espn_injuries_snapshots e
  USING ordered o
  WHERE e.id = o.id
    AND o.prev_content IS NOT DISTINCT FROM o.content;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  -- (2) Recompute is_baseline over the surviving rows so downstream
  --     `is_baseline=false` (real-changes-only) filters work on history.
  WITH firsts AS (
    SELECT DISTINCT ON (espn_league, espn_team_id,
                        lower(btrim(coalesce(athlete_name, athlete_id, ''))))
      id
    FROM public.espn_injuries_snapshots
    ORDER BY espn_league, espn_team_id,
             lower(btrim(coalesce(athlete_name, athlete_id, ''))),
             captured_at, id
  )
  UPDATE public.espn_injuries_snapshots e
  SET is_baseline = (e.id IN (SELECT id FROM firsts))
  WHERE e.is_baseline IS DISTINCT FROM (e.id IN (SELECT id FROM firsts));
  GET DIAGNOSTICS v_fixed = ROW_COUNT;

  RETURN QUERY SELECT v_deleted, v_fixed;
END;
$$;

REVOKE ALL ON FUNCTION public.espn_injuries_sweep() FROM PUBLIC;

COMMENT ON FUNCTION public.espn_injuries_sweep() IS
  'Maintenance: collapse per-poll injury churn (ESPN provisional athlete-id churn, '
  'mig 20260520220000 Arias flood) by keeping the first row of every distinct-state '
  'run per stable identity (league, team, lower(name)); then recompute is_baseline. '
  'Idempotent. Scheduled daily (espn_injuries_sweep_daily). Paired with espn-collect '
  'v8 stable dedup key which prevents new churn.';

-- One-time cleanup on apply (idempotent — re-apply is a no-op DELETE).
SELECT * FROM public.espn_injuries_sweep();

-- Daily retention sweep. :17 off-minute, 04:00 UTC off-peak (avoids the
-- saturated :02/:05/:07 clusters). Bounds any residual churn (e.g. any polls
-- between apply and the espn-collect v8 deploy).
SELECT cron.unschedule('espn_injuries_sweep_daily')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn_injuries_sweep_daily');

SELECT cron.schedule(
  'espn_injuries_sweep_daily',
  '17 4 * * *',
  $$ SELECT public.espn_injuries_sweep(); $$
);
