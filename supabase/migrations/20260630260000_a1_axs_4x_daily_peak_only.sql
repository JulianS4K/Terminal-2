-- ============================================================================
-- Migration 20260630260000 — AXS probe: 4 pulls/day, peak-only
--
-- Lane:     A1
-- Touches:  cron job 'axs-probe-drain' (command only; schedule stays '* * * * *').
-- Pre-reqs: 20260630160000 (axs_probe_step credit charge + is_peak gate), is_peak(), td_budget_ok().
--
-- WHY (operator 2026-06-30 "pull all axs 4 times a day during peak times"): set the AXS probe cadence to
-- ~4 refreshes/day per confirmed-AXS event, executed ONLY during the data-derived peak window (is_peak()
-- = ET 09:00-01:59), and drop the prior off-peak fire (`minute % 10 = 8`).
--   MECHANISM: axs_probe_step(p_refresh_hours) gates each axs_ok event's re-probe on
--   `last_pulled_at < now() - p_refresh_hours`. 24h / 6h = 4 due windows/day; peak-only firing defers any
--   off-peak-due refresh to the next peak tick, so each event still resolves to ~4 pulls/day, all in peak.
--   Throughput: 217 confirmed-AXS events × 4 = ~868 fetches/day; the drain fires 1/min × 17h peak = ~1,020
--   ticks/day → fits. veritix events bypass the function's 30-min non-veritix backoff, so they re-fire as
--   soon as due.
--
-- NOTE (TD AXS maintenance, observed 2026-06-30): TD's /fetch?platform=axs is currently returning HTTP-200
--   bodies `{"status":500,"error":"Scheduled maintenance ..."}` for every event (0 veritix, 0 snapshots
--   since 6/29 20:40). This is an UPSTREAM outage, not a cadence issue. The function's existing 30-min
--   non-veritix backoff already throttles re-fires during the outage; peak-only further cuts the off-peak
--   fetches against the dead endpoint. Once TD's feed returns veritix data, the 6h/peak cadence yields the
--   requested 4 pulls/day automatically — no further change needed.
--
-- Idempotent (cron.alter_job by name; re-apply is a no-op).
-- ============================================================================

DO $do$
DECLARE j bigint;
BEGIN
  SELECT jobid INTO j FROM cron.job WHERE jobname = 'axs-probe-drain';
  IF j IS NULL THEN
    RAISE NOTICE 'axs-probe-drain not found — skipping';
    RETURN;
  END IF;

  PERFORM cron.alter_job(
    job_id  := j,
    command := $cmd$do $b$ begin
    if public.is_peak() and public.td_budget_ok() then
      perform public.axs_probe_step(p_refresh_hours => 6);
    end if;
  end $b$;$cmd$
  );
END $do$;
