-- ============================================================================
-- Migration 20260826140000 — order intakes: resume SeatGeek polling, poll Vivid
--                            for SHIPPED/FULFILLED, add daily all-state sweeps
--
-- Lane:     D0/A1 (order ingest) → applier (apply)
-- Touches:  vivid_orders_queue_multi() (W — new fn),
--           cron.job (W — 2 rescheduled, 2 new), cron_policy (W — 3 rows),
--           vivid_orders_queue() (R — called, unchanged),
--           sg_seller_orders_queue() (R — called, unchanged)
-- Pre-reqs: vault VIVID_API_TOKEN + SEATGEEK_API_TOKEN; cron_should_fire()
--           (mig 20260515250000)
--
-- WHY
--   Two of the four owned-order intakes contribute zero realized sales:
--
--   VIVID — `vivid_orders_queue(p_status DEFAULT 'PENDING_SHIPMENT')` fires ONE
--   HTTP GET for ONE status, and the cron calls it bare. So the poller has only
--   ever asked Vivid for PENDING_SHIPMENT. Result on prod 2026-08-26: 6,490 of
--   6,491 rows sit at PENDING_SHIPMENT, which order_status_xref maps to
--   is_sale_succeeded=false. 3,525 of those are for events that ALREADY
--   HAPPENED; the oldest order dates to 2019. The statuses that count as sales
--   (FULFILLED, SHIPPED) were never requested, so no Vivid order has ever
--   become a sale line. 4,431 of the 6,491 already carry tevo_event_id, so the
--   rows are mappable — only the status was missing.
--
--   SEATGEEK — `sg_seller_orders_queue_30min` has been inactive since
--   2026-06-19; the table is frozen at 400 rows.
--
-- WHAT THIS DOES
--   1. vivid_orders_queue_multi(csv) — loops a status list, delegating each to
--      the existing single-status queue fn. No new HTTP shape, no new parsing;
--      vivid_orders_process() already upserts ON CONFLICT (vivid_order_id) DO
--      UPDATE SET status = EXCLUDED.status, so a re-poll under a new status
--      transitions the existing row in place rather than duplicating it.
--   2. vivid_orders_queue_30min now polls the three HOT states
--      (PENDING_SHIPMENT, SHIPPED, FULFILLED) instead of one.
--   3. sg_seller_orders_queue_30min resumed, and its status list now includes
--      'delivered' — which order_status_xref counts as a sale but which the
--      function's default array omitted. Moved off minute :02 (saturated
--      cluster) to :09/:39, and wrapped in cron_should_fire() like its peers.
--   4. Two new daily all-state sweeps at 05:34 / 05:44 UTC — deliberately
--      BEFORE d0_refresh_sales_fact_nightly (06:40 UTC) so a status that
--      settles overnight is in the fact table the same morning. These catch
--      terminal transitions (CANCELED / REJECTED / substitutions) that the hot
--      poll does not ask for.
--
-- READ-ONLY UPSTREAM (CLAUDE.md rule 2)
--   Every call added here is an HTTP GET against an order-listing endpoint
--   (Vivid getOrders, SG /orders). Nothing writes, holds, prices, or mutates
--   anything upstream. This widens which statuses we ASK about; it does not
--   widen what we can DO.
--
-- NOT FIXED HERE
--   All 400 seatgeek_orders resolve to an aq_event_map row whose tevo_event_id
--   is NULL, so the existing backfill correctly maps none of them. That is a
--   catalog-resolution gap upstream of orders, not an order bug — resuming the
--   poll brings in fresh orders but does not retro-map the frozen 400.
--   TickPick stays off: its rows carry statuses 'Scheduled'/'Rescheduled',
--   which are absent from order_status_xref entirely, so nothing it ingests
--   could be counted until that vocabulary is reconciled.
--
-- Idempotent + reversible: CREATE OR REPLACE, cron.schedule upsert-by-name,
-- and ON CONFLICT policy upserts. Re-applying is a no-op.
-- ============================================================================

begin;

-- 1. Multi-status Vivid queue. ------------------------------------------------
create or replace function public.vivid_orders_queue_multi(
  p_statuses text default 'PENDING_SHIPMENT,SHIPPED,FULFILLED'
)
returns integer
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_status  text;
  v_fired   int := 0;
begin
  foreach v_status in array string_to_array(p_statuses, ',') loop
    v_status := trim(v_status);
    continue when v_status = '';
    -- Delegate to the existing single-status fn: same URL shape, same pending
    -- row, same token handling. One GET per status.
    v_fired := v_fired + coalesce(public.vivid_orders_queue(v_status), 0);
  end loop;
  return v_fired;
end;
$function$;

comment on function public.vivid_orders_queue_multi(text) is
  'Queues one Vivid getOrders GET per status in a CSV list (default: the three '
  'hot states PENDING_SHIPMENT,SHIPPED,FULFILLED). Delegates each to '
  'vivid_orders_queue(status). Read-only upstream. Added 20260826140000 — the '
  'bare vivid_orders_queue() only ever polled PENDING_SHIPMENT, so no Vivid '
  'order ever reached a status that order_status_xref counts as a sale.';

-- 2. Vivid hot poll — three states instead of one. ----------------------------
select cron.schedule(
  'vivid_orders_queue_30min',
  '16 * * * *',
  $cron$DO $body$ BEGIN IF NOT public.cron_should_fire('vivid_orders_queue_30min') THEN RETURN; END IF; PERFORM public.vivid_orders_queue_multi('PENDING_SHIPMENT,SHIPPED,FULFILLED'); END $body$;$cron$
);

-- 3. Vivid daily all-state sweep. ---------------------------------------------
select cron.schedule(
  'vivid_orders_queue_all_daily',
  '34 5 * * *',
  $cron$DO $body$ BEGIN IF NOT public.cron_should_fire('vivid_orders_queue_all_daily') THEN RETURN; END IF; PERFORM public.vivid_orders_queue_multi('PENDING_SHIPMENT,SHIPPED,FULFILLED,PENDING_RETRANSFER,CANCELED,CANCELLED,REJECTED'); END $body$;$cron$
);

-- 4. SeatGeek hot poll — resumed, off :02, with 'delivered' included. ---------
select cron.schedule(
  'sg_seller_orders_queue_30min',
  '9,39 * * * *',
  $cron$DO $body$ BEGIN IF NOT public.cron_should_fire('sg_seller_orders_queue_30min') THEN RETURN; END IF; PERFORM public.sg_seller_orders_queue(3, 'open,pending,confirmed,fulfilled,delivered'); END $body$;$cron$
);

-- 4b. Re-activate the SG job. --------------------------------------------------
--     cron.schedule() upserts a job's SCHEDULE and COMMAND by name, but it does
--     NOT flip `active` back to true on a job that was previously deactivated —
--     verified against prod on 2026-08-26, where step 4 landed the new schedule
--     and command while the job stayed active=false. Without this the "resume"
--     is silently a no-op.
do $$
declare v_id bigint;
begin
  select jobid into v_id from cron.job where jobname = 'sg_seller_orders_queue_30min';
  if v_id is not null then
    perform cron.alter_job(v_id, active := true);
  end if;
end $$;

-- 5. SeatGeek daily all-state sweep. ------------------------------------------
select cron.schedule(
  'sg_seller_orders_queue_all_daily',
  '44 5 * * *',
  $cron$DO $body$ BEGIN IF NOT public.cron_should_fire('sg_seller_orders_queue_all_daily') THEN RETURN; END IF; PERFORM public.sg_seller_orders_queue(3, 'open,pending,confirmed,fulfilled,delivered,cancelled,pending_substitution'); END $body$;$cron$
);

-- 6. Rate policy for the resumed + new jobs. ----------------------------------
--    SG carries a documented 429 history (10 req / 8s bucket), and each fire
--    now costs one GET per status — 5 on the hot poll, 7 on the daily sweep.
insert into public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, notes)
values
  ('sg_seller_orders_queue_30min', ARRAY[12,13,14,15,16,17,18,19,20,21,22,23], 30, 120, 30,
   'Resumed 2026-08-26 (inactive since 06-19). 5 GETs/fire (open,pending,confirmed,fulfilled,delivered). Peak mirrors sg_seller_process_30min; capped for the SG 10req/8s bucket.'),
  ('vivid_orders_queue_all_daily', ARRAY[]::int[], 720, 720, 2,
   'Daily all-state sweep 05:34 UTC, before d0_refresh_sales_fact_nightly (06:40). 7 GETs/fire.'),
  ('sg_seller_orders_queue_all_daily', ARRAY[]::int[], 720, 720, 2,
   'Daily all-state sweep 05:44 UTC, before d0_refresh_sales_fact_nightly (06:40). 7 GETs/fire.')
on conflict (jobname) do update set
  peak_hours_et            = excluded.peak_hours_et,
  peak_min_interval_min    = excluded.peak_min_interval_min,
  offpeak_min_interval_min = excluded.offpeak_min_interval_min,
  daily_max_fires          = excluded.daily_max_fires,
  notes                    = excluded.notes,
  updated_at               = now();

-- The Vivid hot poll keeps its existing policy row (peak 7-18 ET, 15/60 min,
-- 60 fires/day); it now costs 3 GETs per fire instead of 1, which stays well
-- inside Vivid's limits. Left untouched deliberately.

commit;
