-- Migration 20260515250003 · level:admin · lane:Audit/Push · writes:cron_pause_state_20260514 schedule for 5 TEvo collect-listings-* jobs · pre:20260515250002
-- Operator directive 2026-05-14: "halve these" (TEvo collect-listings-* cadences).
-- Updates the snapshot schedules; cron_resume_with_gate() reads from there
-- so when the operator graduates each cron, it comes back at the new cadence.
--
-- ## Already applied to prod  Applied via MCP 2026-05-14.

UPDATE public.cron_pause_state_20260514 SET schedule = '1-59/10 * * * *'
  WHERE jobname = 'collect-listings-0-24h';     -- was 1-59/20 (every 20m) -> every 10m
UPDATE public.cron_pause_state_20260514 SET schedule = '30 5,17 * * *'
  WHERE jobname = 'collect-listings-1-7d';      -- was '30 5'   (1/day) -> 2/day
UPDATE public.cron_pause_state_20260514 SET schedule = '20 4,16 * * *'
  WHERE jobname = 'collect-listings-7-30d';     -- was '20 4'   (1/day) -> 2/day
UPDATE public.cron_pause_state_20260514 SET schedule = '35 4,16 * * *'
  WHERE jobname = 'collect-listings-30-60d';    -- was '35 4'   (1/day) -> 2/day
UPDATE public.cron_pause_state_20260514 SET schedule = '50 4,16 * * *'
  WHERE jobname = 'collect-listings-60d+';      -- was '50 4'   (1/day) -> 2/day
