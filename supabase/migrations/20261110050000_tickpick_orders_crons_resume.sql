-- Migration 20261110050000 · level:data-collection · lane:A1 · writes:cron(tickpick_orders_queue_30min,tickpick_orders_process_30min) · reads:none · pre:20261110040000
--
-- Resume the TickPick order sync crons (operator 2026-11-10: "turn the tickpick order sync crons
-- back on"). They were paused by 20260515360000 because every call returned 401: the vault
-- TICKPICK_API_TOKEN had been saved cut off. Since 20261110020000 the token is refreshed from the
-- vault credentials and works (account tu@s4kent.com). Verified before resuming (2026-11-09 23:20
-- UTC): one manual queue + process cycle → GET /1.0/orders?status=unfulfilled 200 (4 MB),
-- 1,778 orders persisted into tickpick_orders. GET only; tickpick_orders_queue/_process unchanged.
-- Applied on prod by cron.alter_job at 23:21 UTC; this file is the record (idempotent).
--
-- rollback: re-run 20260515360000 (sets both jobs active := false).

SELECT cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname = 'tickpick_orders_queue_30min'),   active := true);
SELECT cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname = 'tickpick_orders_process_30min'), active := true);
