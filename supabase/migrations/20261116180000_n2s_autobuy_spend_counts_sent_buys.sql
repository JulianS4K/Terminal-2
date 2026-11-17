-- Migration 20261116180000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_enqueue_trg · reads:n2s_autobuy_exec · pre:20261113400000
--
-- A live row that STOPPED BEFORE ANY BUY no longer counts as spend.
--
-- Found 2026-11-16: the first live attempt (exec 8, TickPick sale 1074350318) stopped with
-- sale_read_failed before anything was sent: phase 'stopped', no purchase id, nothing bought.
-- Its state stays 'live_buy', and n2s_autobuy_enqueue_trg counts every 'live_buy' row as spent,
-- so the next EVO cover (exec 9, dryrun 618, $620.14) read $449.68 already spent today and on
-- the project, and was blocked over_daily_cap and over_project_cap. The project count never
-- resets: until this, every EVO cover above $216.32 would be blocked for good.
--
-- The five places the trigger counts a committed buy (today's spend, today's buys, project
-- spend, event_already_bought_today, listing_already_used) now skip a row whose phase is
-- 'stopped' and which has no purchase id. Everything else still counts, failing toward the
-- stricter cap:
--   - a row with a purchase id counts even when stopped (the sale went away after we bought, or
--     the sub was rejected: money may be out until the market refunds it);
--   - buy_unknown / accept_unknown / accept_failed count;
--   - 'queued' (filed into the one queue, 20261113470000) and rows not claimed yet count;
--   - shadow rows (phase NULL) count, as before.
-- 'stopped' with no purchase id only happens when nothing was bought: the worker stopped before
-- sending, the market refused the buy (buy_failed, 4xx: nothing created), or the one queue
-- refused the filing (queue_file_refused).
--
-- md5-guarded anchor patch on the prod text of 20261113400000; 5 anchors, all one literal.

DO $do$
DECLARE d text; n int;
BEGIN
  d := pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure);
  IF md5(d) <> '01289b140c53b4e62fa2952072cff218' THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg drifted from 20261113400000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, $r$state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')$r$, '')))
       / length($r$state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')$r$);
  IF n <> 5 THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg: % of 5 anchors found — re-derive this migration', n;
  END IF;
  -- In the three unqualified counts the columns are n2s_autobuy_exec's; in the two x. subqueries
  -- (FROM public.n2s_autobuy_exec x) the bare names resolve to x's columns, the only table there.
  d := replace(d, $r$state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')$r$,
    $r$state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL)$r$);
  EXECUTE d;
END $do$;
