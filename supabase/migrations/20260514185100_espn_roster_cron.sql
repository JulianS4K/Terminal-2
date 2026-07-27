-- Migration 20260514185100 · level:admin · lane:Audit/Push · writes:cron(espn-roster-10min) · reads:- · pre:20260514185000
-- Data-bug fix #2: ESPN injuries_snapshots stale 61h.
--
-- Same shape as the gameday cron restoration in 20260514185000.
-- Historical jobid 24 fired `espn-collect?scope=roster` every 10 min until
-- 2026-05-09 — dropped in the same cron cleanup that killed jobid 25.
-- Result: per-athlete injury rows stopped updating while team_daily kept
-- working (team_daily intentionally has injuries=false in its scope).
--
-- One-shot verification 2026-05-14 18:06 UTC (request_id 12484): scope=roster
-- ran cleanly, inserted 126 injuries, log confirms `injuries=true` and all
-- leagues reporting team-counts (mlb=30, etc.).
--
-- Schedule offset by 5 min from the gameday cron (jobid 128) to avoid
-- simultaneous ESPN API hits and the pg_cron worker-pool startup-timeout
-- pattern that hit every job during the IO incident.
--
-- Created ACTIVE=FALSE so it joins the paused fleet from bot_chat row 106.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 ~18:07 UTC. Jobid 129 created + paused.
-- Idempotent codification per SYNC_PROTOCOL §5.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn-roster-10min') THEN
    PERFORM cron.schedule(
      'espn-roster-10min',
      '5-59/10 * * * *',
      $cmd$ SELECT public._cron_invoke_edge_fn(
              'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=roster',
              '{}'::jsonb); $cmd$
    );
    PERFORM cron.alter_job(
      job_id := (SELECT jobid FROM cron.job WHERE jobname = 'espn-roster-10min'),
      active := false
    );
  END IF;
END $$;
