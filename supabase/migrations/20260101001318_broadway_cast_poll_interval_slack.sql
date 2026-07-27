-- Migration 20260704170000 · level:standard · lane:broadway (D3)/A1 · writes:cron_policy · reads: · pre:20260703014000
--
-- Fix a boundary race that made the daily Broadway cast poll self-skip. The
-- seed (20260703014000) set offpeak/peak_min_interval_min = 1440 (24h) on a job
-- that pg_cron ticks every 24h ('43 13 * * *'). cron_should_fire gates with
-- `(clock_timestamp() - last_fire) < interval`; because the recorded last-fire
-- timestamp lands a few hundred microseconds AFTER the tick, a same-length 24h
-- gate computes elapsed as 1439.9996 min < 1440 and returns skip_offpeak — the
-- 2026-07-04 run was dropped this way. daily_max_fires=1 already caps the job to
-- one fire per UTC day, so the interval gate only needs to be loose enough to
-- clear a 24h cadence. Slacken it to 1200 (20h): 24h tick > 20h gate always
-- passes, and the daily budget still prevents any double-fire.
--
-- Idempotent: re-running just re-asserts 1200. (The seed's ON CONFLICT clause
-- deliberately does not touch the interval columns, so this is the canonical
-- home for their value.)

UPDATE public.cron_policy
SET peak_min_interval_min   = 1200,
    offpeak_min_interval_min = 1200,
    updated_at              = now()
WHERE jobname = 'broadway_cast_collect_daily'
  AND (peak_min_interval_min <> 1200 OR offpeak_min_interval_min <> 1200);
