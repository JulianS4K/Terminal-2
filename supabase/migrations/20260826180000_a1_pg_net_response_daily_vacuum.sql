-- Migration 20260826180000 · lane:A1 (data plane — DB maintenance/crons) ·
--   writes (DDL): public.vacuum_pg_net_responses() (new SECURITY DEFINER fn) ·
--   writes on run: cron.schedule('pg_net_response_vacuum_daily', …) ·
--   reads: pg_stat_all_tables, pg_class (size/stat reporting only) ·
--   spends: nothing (no upstream calls) ·
--   pre: pg_net extension present (net._http_response); pg_cron present
--
-- ## NOT YET APPLIED — author-only. Apply + the cron.schedule call are
--    operator-directed Applier actions (CLAUDE.md Rule 1: cron schedule
--    changes need explicit permission — granted 2026-08-26). Idempotent
--    (CREATE OR REPLACE + cron.unschedule-then-schedule guarded by a lookup).
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- `net._http_response` measured **52 GB on disk holding 23,393 live rows and
-- 0 dead tuples** (2026-08-26). Its only index is on `created`, so any lookup
-- by `id` full-scans all 52 GB — this is why ad-hoc `WHERE id = <req>` probes
-- time out. pg_net deletes its own rows on TTL, so the rows are gone; what
-- remains is free-but-unreclaimed space inside the heap file. Last autovacuum
-- was 2026-08-05 and `last_analyze` is NULL — the planner has no stats on it
-- at all.
--
-- WHAT THIS DOES *NOT* DO — read this before expecting the 52 GB back ───────
-- A plain VACUUM does NOT shrink the file. With n_dead_tup = 0 the space is
-- already free *within* the heap; only the OS-level reclaim is missing, and
-- that needs a rewrite (VACUUM FULL / pg_repack). So this cron:
--   ✔ keeps the free-space map current, so the file is REUSED and stops
--     growing past its current high-water mark
--   ✔ refreshes planner stats (ANALYZE) — currently never run on this table
--   ✔ costs no locks that block writers (plain VACUUM is concurrent-safe)
--   ✘ does NOT return the 52 GB to the filesystem
--
-- Reclaiming the 52 GB is a SEPARATE one-time operator action, deliberately
-- NOT scheduled here: `VACUUM FULL net._http_response` takes an ACCESS
-- EXCLUSIVE lock and rewrites the whole heap. Every pg_net caller in the
-- project (all TD/AXS/SG polling) blocks for the duration. That belongs in a
-- maintenance window, run by hand — never on a daily timer, which is why this
-- migration schedules the plain VACUUM only. See the runbook at the foot.
--
-- WHY A WRAPPER FUNCTION rather than scheduling `VACUUM` as the cron command:
--   1. VACUUM cannot run inside a transaction block. pg_cron executes a raw
--      single statement outside one, so bare `VACUUM …` does work — but it
--      gives us no logging and no guard if the relation is absent.
--   2. `net._http_response` is owned by `supabase_admin` while cron jobs run
--      as `postgres`. SECURITY DEFINER on a function owned by a role with
--      rights keeps this working if role grants shift later.
--   3. We want a row in the existing cron/maintenance log rather than a
--      silent success.
-- NOTE: the function body uses no explicit transaction control; VACUUM is
-- issued via EXECUTE in a plpgsql block, which pg_cron runs in autocommit.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.vacuum_pg_net_responses()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_before_bytes bigint;
  v_after_bytes  bigint;
  v_live         bigint;
  v_msg          text;
BEGIN
  -- Guard: if pg_net is absent (fresh/limited env), no-op rather than error.
  IF to_regclass('net._http_response') IS NULL THEN
    RETURN 'skipped: net._http_response not present';
  END IF;

  SELECT pg_total_relation_size('net._http_response') INTO v_before_bytes;

  -- Plain VACUUM + ANALYZE. No FULL: see the header — FULL takes an ACCESS
  -- EXCLUSIVE lock and would stall every pg_net caller in the project.
  EXECUTE 'VACUUM (ANALYZE) net._http_response';

  SELECT pg_total_relation_size('net._http_response') INTO v_after_bytes;
  SELECT n_live_tup INTO v_live
    FROM pg_stat_all_tables
   WHERE schemaname = 'net' AND relname = '_http_response';

  v_msg := format(
    'vacuum_pg_net_responses: %s -> %s (live_tuples=%s). Plain VACUUM does not '
    || 'return space to the OS; run VACUUM FULL in a maintenance window to reclaim.',
    pg_size_pretty(v_before_bytes), pg_size_pretty(v_after_bytes),
    COALESCE(v_live, 0));

  RAISE NOTICE '%', v_msg;
  RETURN v_msg;
END;
$function$;

-- Least-privilege: this is maintenance, not an app surface.
REVOKE ALL ON FUNCTION public.vacuum_pg_net_responses() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.vacuum_pg_net_responses() TO service_role;

COMMENT ON FUNCTION public.vacuum_pg_net_responses() IS
  'Daily plain VACUUM (ANALYZE) of net._http_response. Keeps the free-space map '
  'and planner stats current so the 52 GB heap is reused rather than grown. Does '
  'NOT reclaim disk — that needs a one-time VACUUM FULL in a maintenance window.';


-- ── Schedule: daily 04:35 UTC ────────────────────────────────────────────────
--    Slot choice: avoids the saturated :02/:05/:07 minute marks (CLAUDE.md /
--    PR checklist) and the crowded 03:0x-03:5x band (sweep-bot-messages 03:05,
--    midnight-catchup 03:20, wiki_pending 03:23, orphan_backfill 03:30,
--    sweep-bot-chat-noise 03:43, athlete_wiki 03:45, inactive_event_states
--    03:50) plus 04:10/04:17/04:30. 04:35 is free.
DO $sched$
BEGIN
  PERFORM cron.unschedule('pg_net_response_vacuum_daily')
   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pg_net_response_vacuum_daily');

  PERFORM cron.schedule(
    'pg_net_response_vacuum_daily',
    '35 4 * * *',
    $job$ SELECT public.vacuum_pg_net_responses(); $job$
  );
END
$sched$;


-- ── Operator runbook ─────────────────────────────────────────────────────────
-- Verify the job registered:
--   SELECT jobname, schedule, active FROM cron.job
--    WHERE jobname = 'pg_net_response_vacuum_daily';
--
-- Run it once by hand (safe, no blocking lock; takes minutes on a 52 GB heap —
-- expect it to exceed a 60s client timeout, so run it from a session that waits):
--   SELECT public.vacuum_pg_net_responses();
--
-- Check the outcome:
--   SELECT last_vacuum, last_analyze, n_live_tup, n_dead_tup,
--          pg_size_pretty(pg_total_relation_size('net._http_response')) AS size
--     FROM pg_stat_all_tables WHERE schemaname='net' AND relname='_http_response';
--
-- RECLAIM THE 52 GB (one-time, MAINTENANCE WINDOW ONLY — not scheduled here):
--   -- ACCESS EXCLUSIVE lock; blocks EVERY pg_net caller (all TD/AXS/SG polling)
--   -- for the whole rewrite. Quiesce the pollers first, then:
--   VACUUM FULL net._http_response;
--   -- Lower-lock alternative if the pg_repack extension is available:
--   -- pg_repack -t net._http_response
--
-- CONSIDER ALSO (not done here — needs its own decision):
--   pg_net's response TTL governs how much this table holds. If 52 GB is the
--   steady-state high-water mark rather than a one-off spike, shortening the
--   TTL is the durable fix; the daily VACUUM only stops it growing further.
--
-- ROLLBACK:
--   SELECT cron.unschedule('pg_net_response_vacuum_daily');
--   DROP FUNCTION IF EXISTS public.vacuum_pg_net_responses();
