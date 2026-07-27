-- 20260526030000_fix_sg_blindspot_cron_statement_timeout.sql
--
-- A1-4 (D0 handoff, 2026-05-26): fix sg_blindspot_mv_refresh cron timing out.
--
-- ROOT CAUSE (verified empirically by D0, 2026-05-25):
--   The cron body is a single DO block. Inside the block,
--   `SET LOCAL statement_timeout = '5min'` runs AFTER the DO block statement
--   has already started — it cannot retroactively re-arm the outer statement's
--   timer. In effect the REFRESH runs without any timeout cap, and on cold cache
--   it spins indefinitely without being killed.
--   Last successful refresh: 2026-05-25 10:13 UTC → data stale 9h+ at time of
--   D0 handoff.
--
-- FIX: move SET statement_timeout OUT of the DO block as a separate leading
--   statement. pg_cron executes multi-statement commands sequentially; the first
--   statement `SET statement_timeout = '10min'` takes effect before the DO block
--   begins, so the DO block — and the REFRESH inside it — starts fresh with the
--   configured 10-min budget.
--
-- PATTERN NOTE (§3 landmine): `SET LOCAL` inside a DO block does not re-arm
--   the timer of the currently-running outer statement. Always place
--   `SET statement_timeout` as a standalone statement before any DO block in
--   pg_cron commands that need a non-default timeout.
--
-- ROLLBACK: re-run with the old DO-block body (puts SET LOCAL back inside),
--   or SET statement_timeout = DEFAULT to clear the session var if needed.

SELECT cron.unschedule('sg_blindspot_mv_refresh');

SELECT cron.schedule(
  'sg_blindspot_mv_refresh',
  '3-59/10 * * * *',
  $$SET statement_timeout = '10min'; DO $body$ BEGIN IF NOT public.cron_should_fire('sg_blindspot_mv_refresh') THEN RETURN; END IF; REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_sg_blindspot_movers; END $body$;$$
);
