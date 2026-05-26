-- 20260526060000_fix_sg_blindspot_cron_non_concurrent.sql
--
-- PROBLEM: sg_blindspot_mv_refresh is timing out even with the 10-min budget
-- added in 20260526030000. Root cause: REFRESH MATERIALIZED VIEW CONCURRENTLY
-- on mv_sg_blindspot_movers (33 rows, 104 kB) requires a full re-scan of
-- seatgeek_listings_snapshots (7.3 GB, 8M+ rows) to compute the diff.
-- At the current DB load this exceeds 10 minutes.
--
-- FIX: drop CONCURRENTLY. Non-concurrent refresh on a 33-row matview:
--   - Takes an exclusive lock for the duration, but on 33 rows it's trivial
--     (milliseconds vs minutes for CONCURRENTLY on a 7 GB table scan).
--   - No read-blocking concern: the terminal reads mv_sg_blindspot_movers
--     via get_blind_spots_sg_selling(), which is itself fast; the 5-10s lock
--     window is undetectable in practice.
--
-- §3 LANDMINE: REFRESH MATERIALIZED VIEW CONCURRENTLY is only worth the
-- cost when the matview is large enough that blocking reads during refresh
-- is unacceptable. For small derived matviews (<1k rows) that read from
-- large base tables, non-concurrent is always faster. The CONCURRENTLY
-- flag optimises for lock avoidance, not speed.
--
-- Also bumps timeout to 5min (generous for 33 rows; was 10min and still
-- timing out due to the CONCURRENTLY diff computation).
--
-- ROLLBACK: re-run with CONCURRENTLY added back and bump timeout to 30min+.

SELECT cron.unschedule('sg_blindspot_mv_refresh');

SELECT cron.schedule(
  'sg_blindspot_mv_refresh',
  '3-59/10 * * * *',
  $$SET statement_timeout = '5min'; DO $body$ BEGIN IF NOT public.cron_should_fire('sg_blindspot_mv_refresh') THEN RETURN; END IF; REFRESH MATERIALIZED VIEW public.mv_sg_blindspot_movers; END $body$;$$
);
