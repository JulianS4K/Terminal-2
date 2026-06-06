-- Drop the dead single-arg overload of td_enqueue_peak.
-- The two-arg version (p_platform text, p_interval_tag text) is the active one used by
-- td_enqueue_peak_sh/gt/vd crons. The old single-arg version (LIMIT 80, no platform scope)
-- is unreachable by any cron and is a credit-burn risk if called manually.

DROP FUNCTION IF EXISTS public.td_enqueue_peak(text);

-- ## Already applied to prod  Applied via MCP 2026-05-27
