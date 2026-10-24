-- ============================================================================
-- Migration 20260826150000 — Vivid: narrow polling back to the ONLY status the
--                            broker API actually accepts
--
-- Lane:     D0/A1 (order ingest) → applier (apply)
-- Touches:  cron.job (W — vivid_orders_queue_30min re-pointed,
--           vivid_orders_queue_all_daily unscheduled), cron_policy (W — 1 row disabled)
-- Pre-reqs: mig 20260826140000
--
-- WHY — measured, not assumed
--   20260826140000 widened the Vivid poll to PENDING_SHIPMENT,SHIPPED,FULFILLED
--   on the assumption that the seven statuses in order_status_xref were all
--   valid filter values. They are not. Probing every one of them against the
--   live endpoint on 2026-08-26 gave, via vivid_orders_pending.rows_persisted
--   (-1 = non-200 from the processor's HTTP-failure path):
--
--     status=PENDING_SHIPMENT  ->  104 rows persisted   OK
--     status=SHIPPED           ->   -1                  HTTP failure
--     status=FULFILLED         ->   -1                  HTTP failure
--     status=REJECTED          ->   -1                  HTTP failure
--     status=CANCELED          ->   -1                  HTTP failure
--
--   REJECTED and CANCELED would return small result sets, so this is NOT the
--   30s pg_net timeout on a large body — that hypothesis is ruled out. Vivid's
--   getOrders rejects every status filter except PENDING_SHIPMENT. The other
--   six values in order_status_xref are aspirational: they were seeded as
--   expected vocabulary and have never been observed from this endpoint, which
--   is precisely why 100% of vivid_orders sit at PENDING_SHIPMENT.
--
-- WHAT THIS DOES
--   Reverts the recurring polls to the one working status so we stop firing
--   known-failing requests at a broker API twice an hour (and six more daily).
--   vivid_orders_queue_multi() is KEPT — it is correct and needed the moment we
--   know the right call shape; only its arguments were wrong.
--
-- WHAT REMAINS BROKEN (deliberately not papered over)
--   No Vivid order can become a realized sale until we can observe a status
--   that order_status_xref counts as one. Open probe: getOrders with NO status
--   parameter (vivid_orders_pending 'PROBE:no-status-param'). If that returns
--   all orders, drop status filtering entirely; if it also fails, the fulfilled
--   side needs a different endpoint or broker-portal export, and that is a
--   question for Vivid, not a code change.
--
--   The SeatGeek half of 20260826140000 is unaffected and IS working —
--   seatgeek_orders.last_pull moved from 2026-06-19 to 2026-08-26 18:16.
--
-- Idempotent + reversible.
-- ============================================================================

begin;

-- 1. Hourly Vivid poll: back to the one status the API accepts. ---------------
select cron.schedule(
  'vivid_orders_queue_30min',
  '16 * * * *',
  $cron$DO $body$ BEGIN IF NOT public.cron_should_fire('vivid_orders_queue_30min') THEN RETURN; END IF; PERFORM public.vivid_orders_queue_multi('PENDING_SHIPMENT'); END $body$;$cron$
);

-- 2. Daily all-state sweep: every status it would add is a known 400/500. -----
--    Unschedule rather than narrow — narrowed to PENDING_SHIPMENT it would just
--    duplicate the hourly poll.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'vivid_orders_queue_all_daily') then
    perform cron.unschedule('vivid_orders_queue_all_daily');
  end if;
end $$;

update public.cron_policy
   set enabled = false,
       notes = 'DISABLED 2026-08-26 (mig 20260826150000): Vivid getOrders accepts only '
               || 'status=PENDING_SHIPMENT; SHIPPED/FULFILLED/REJECTED/CANCELED all return '
               || 'non-200 (probed live). Job unscheduled. Re-enable only with a call shape '
               || 'that demonstrably returns fulfilled orders.',
       updated_at = now()
 where jobname = 'vivid_orders_queue_all_daily';

commit;
