-- Migration 20260515360000 · admin · pause failing tickpick crons (vault token bad) · pre:20260515350000
-- 401 from get_app_secret('TICKPICK_API_TOKEN') vs TickPick API. Apps Script ingest
-- (tickpick_orders_ingest_from_apps_script SECDEF RPC) is the working path — 1001 rows
-- in last 24h, 92% aq-matched. Cron path = wasted ticks until operator rotates
-- vault.TICKPICK_API_TOKEN or refactors cron to share Apps Script credential.
-- No data loss: Apps Script remains primary.

SELECT cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname='tickpick_orders_queue_30min'),   active := false);
SELECT cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname='tickpick_orders_process_30min'), active := false);
