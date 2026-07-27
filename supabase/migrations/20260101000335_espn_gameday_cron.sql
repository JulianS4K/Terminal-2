-- Migration 20260514185000 · level:admin · lane:Audit/Push · writes:cron(espn-gameday-10min) · reads:- · pre:20260514183000
-- Data-bug fix #1: ESPN event_snapshots stale 61h.
--
-- Root cause: there is no scheduled cron invoking the `espn-collect` edge
-- function with `?scope=gameday`. Without that scope, `espn_event_snapshots`
-- (per-event scores, spreads, win probabilities, attendance) never refreshes
-- — only team_snapshots / news / standings do.
--
-- History: jobid 25 used to fire this every 10 min until 2026-05-09. The job
-- was dropped during one of the cron cleanups (likely cron-cascade-alignment
-- 20260510080000 or the IO-diet 20260513185058) without a replacement.
--
-- Symptom: `max(captured_at) FROM espn_event_snapshots` stuck at
-- `2026-05-12 04:40:46` — 61 hours stale — until A1 manually invoked the
-- edge fn via pg_net (request_id 12483 at 2026-05-14 18:01 UTC, succeeded
-- with 30 event_snaps_inserted out of 32 processed; 2 errors were the
-- expected stale-event-id 404s).
--
-- Fix: re-schedule the cron at the historical cadence (every 10 min).
-- Created as ACTIVE=FALSE so it joins the paused-fleet from bot_chat row 106
-- (operator directive 2026-05-14 17:15 UTC). Will resume with the rest.
--
-- The edge fn's per-event try/catch handles 404s gracefully (e.g. stale
-- event IDs from postponed/cancelled games) — one 404 doesn't stop the loop.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 ~18:05 UTC. Jobid 128 created + paused.
-- Idempotent codification per SYNC_PROTOCOL §5.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-gameday-10min') THEN
    PERFORM cron.schedule(
      'espn-gameday-10min',
      '*/10 * * * *',
      $cmd$ SELECT public._cron_invoke_edge_fn(
              'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=gameday',
              '{}'::jsonb); $cmd$
    );
    PERFORM cron.alter_job(
      job_id := (SELECT jobid FROM cron.job WHERE jobname = 'espn-gameday-10min'),
      active := false
    );
  END IF;
END $$;
