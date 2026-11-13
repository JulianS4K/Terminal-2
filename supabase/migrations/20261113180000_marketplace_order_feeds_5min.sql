-- Migration 20261113180000 · level:secondary-sales · lane:A1 · writes:cron:gt_sales_sync_15min,cron:gt_sales_drain_15min,cron:tickpick_orders_queue_30min,cron:tickpick_orders_process_30min,cron:vivid_orders_queue_30min,cron:vivid_orders_process_30min,cron:sg_seller_orders_queue_30min,cron:evo_orders_queue_30min,cron:evo_orders_process_30min,cron_policy · reads:none · pre:20261113160000
--
-- MARKETPLACE ORDER FEEDS: every 5 minutes.
--
-- Operator 2026-11-13: "Update marketplace feeds to every 5 mins". The sub finder checks each
-- watched order against its marketplace's own order feed every 2 minutes, but the feeds
-- themselves were refreshed every 15 minutes (GoTickets), 30 (TickPick, SeatGeek, EVO) or 60
-- (Vivid), so a cancelled or delivered sale could be watched, and bought for, that much longer.
--
--   schedule      each feed's "queue" job fires every 5 minutes; its "process" / "drain" job
--                 two minutes later (GoTickets, TickPick, Vivid, EVO). SeatGeek's orders are
--                 landed by sg_seller_process_30min, which already runs every 4 minutes.
--   cron_policy   the queue jobs of TickPick, Vivid, SeatGeek and EVO are gated by
--                 cron_should_fire(): their minimum interval (15-30 min at peak, 60-120 off
--                 peak) and daily fire budget (30-60) would cancel the new schedule, so both
--                 are raised: 4 minutes at any hour, 320 fires a day. The "anything new in 24 h,
--                 or 60 min since the last fire" work check is left as it is.
--
-- The job NAMES keep their old "_15min" / "_30min" suffix: cron_should_fire(), cron_policy
-- and the gate log are keyed on them. Load: one small GET set per fire (SeatGeek 5 GETs,
-- inside its 10-requests-per-8-seconds bucket). All read-only (RULE 2).
--
-- rollback: SELECT cron.alter_job(jobid, schedule := '<old>') FROM cron.job WHERE jobname = '<name>' with
--   gt_sales_sync_15min '3,18,33,48 * * * *' · gt_sales_drain_15min '8,23,38,53 * * * *' ·
--   tickpick_orders_queue_30min '13,43 * * * *' · tickpick_orders_process_30min '15,45 * * * *' ·
--   vivid_orders_queue_30min '16 * * * *' · vivid_orders_process_30min '26 * * * *' ·
--   sg_seller_orders_queue_30min '9,39 * * * *' · evo_orders_queue_30min '0,30 * * * *' · evo_orders_process_30min '5,35 * * * *';
--   UPDATE cron_policy: tickpick / vivid 15, 60, 60 · sg_seller_orders_queue_30min 30, 120, 30 · evo 30, 60, 30
--   (peak_min_interval_min, offpeak_min_interval_min, daily_max_fires).

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('gt_sales_sync_15min',           '3-59/5 * * * *'),
      ('gt_sales_drain_15min',          '0-59/5 * * * *'),
      ('tickpick_orders_queue_30min',   '1-59/5 * * * *'),
      ('tickpick_orders_process_30min', '3-59/5 * * * *'),
      ('vivid_orders_queue_30min',      '2-59/5 * * * *'),
      ('vivid_orders_process_30min',    '4-59/5 * * * *'),
      ('sg_seller_orders_queue_30min',  '4-59/5 * * * *'),
      ('evo_orders_queue_30min',        '0-59/5 * * * *'),
      ('evo_orders_process_30min',      '2-59/5 * * * *')) v(jobname, schedule)
  LOOP
    IF EXISTS (SELECT 1 FROM cron.job j WHERE j.jobname = r.jobname) THEN
      PERFORM cron.alter_job((SELECT j.jobid FROM cron.job j WHERE j.jobname = r.jobname), schedule := r.schedule);
    ELSE
      RAISE NOTICE 'marketplace_order_feeds_5min: no cron job named %', r.jobname;
    END IF;
  END LOOP;
END $$;

UPDATE public.cron_policy
   SET peak_min_interval_min = 4, offpeak_min_interval_min = 4, daily_max_fires = 320, updated_at = now(),
       notes = coalesce(notes, '') || ' [every 5 min at any hour, 320 fires/day: operator 2026-11-13, mig 20261113180000]'
 WHERE jobname IN ('tickpick_orders_queue_30min', 'vivid_orders_queue_30min',
                   'sg_seller_orders_queue_30min', 'evo_orders_queue_30min');
