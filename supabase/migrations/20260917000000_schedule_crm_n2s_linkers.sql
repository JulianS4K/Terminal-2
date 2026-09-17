-- Migration 20260917000000 · level:ops · lane:A1 (+ D7 linker, operator-routed) · writes:cron.job (re-schedules id_spine_tick_15min with the four linkers appended) · pre:20260916235000
--
-- ============================================================================================
-- THE COLUMNS DECAY WITH EVERY CRM PULL UNTIL THE LINKERS RUN ON A TICK
-- ============================================================================================
-- Four linkers were built on 2026-09-16 -- s4kcs_link_gotickets, s4kcs_link_marketplaces,
-- s4kcs_link_tickets_dev, n2s_link_gotickets -- and every one was run by hand. The upstream
-- mapper (s4kcs_map_events) is on a cron; these were not. Measured at 22:00Z: future CRM orders
-- with EVO but no GoTickets had climbed 650 -> 1,012 since the last hand run; 333 of those were
-- orders that ARRIVED after it, 204 of them GoTickets-reachable that minute. tickets.dev had
-- already answered for 192 of 398 missing events and hub_backfill had written the answers into
-- aq_event_map all afternoon; nothing downstream re-read them.
--
-- Operator 2026-09-16: "Fix and merge into prod and run."
--
-- WHERE: the end of id_spine_tick_15min, after everything that can produce a new id in a tick --
-- the anchor pass, tickets_dev_run (harvest + hub_backfill + GoTickets->TEvo), fill_outward, the
-- gt_fallback surfaces. Linkers are the LAST consumers of the tick's work, so they go last.
-- ORDER among the four is the precedence argument from the migrations themselves: the identity-
-- first GoTickets linker before the hub-fed marketplace linker, so the strong route always lands
-- first and the broad one only fills holes; tickets.dev cluster after both (it reads gt_event_id);
-- N2S last (its crm_order route reads the CRM's gt_event_id).
--
-- COST: measured, ~6s a tick -- 1.2 + 2.5 + 1.9 + 0.2 seconds on 28,131 future orders and 191
-- obligations, inside a block that already runs 32-61s against a 170s statement_timeout. Every
-- one is fill-only and idempotent (second dry runs filled zero), so fifteen-minute cadence can
-- never overwrite anything, only catch up. The n2s linker is the 20260916235000 rewrite; the
-- original would have cost a minute a tick and was the reason this could not ship earlier.
--
-- RE-SCHEDULING CHANGES THE JOBID. cron.unschedule + cron.schedule is this repo's convention for
-- editing the tick (20260915090000 and predecessors); the job keeps its NAME and its 8,23,38,53
-- schedule and gets a new jobid. Anything that monitored jobid 652 by number must look up by
-- jobname from now on. cron_should_fire('id_spine_tick_15min') is keyed by name and is unaffected.
--
-- The body below is the CURRENT prod command verbatim (read from cron.job at 22:20Z) plus the
-- four PERFORM lines at the end. Nothing else in it changes.
-- ============================================================================================

DO $cron$
BEGIN
  PERFORM cron.unschedule('id_spine_tick_15min') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'id_spine_tick_15min');
  PERFORM cron.schedule('id_spine_tick_15min', '8,23,38,53 * * * *', $body$
    BEGIN; SET LOCAL statement_timeout = '170s';
    DO $b$ BEGIN
      IF NOT public.cron_should_fire('id_spine_tick_15min') THEN RETURN; END IF;
      PERFORM public.event_mapper_anchor_ids();
      PERFORM public.tickets_dev_run(150);
      PERFORM public.tickets_dev_fill_outward(150);
      PERFORM public.tickets_dev_search_harvest();
      PERFORM public.seatgeek_orders_recover_event_id(true);
      PERFORM public.event_mapper_gt_fallback('s4kcs_orders', true);
      PERFORM public.event_mapper_gt_fallback('vivid_orders', true);
      PERFORM public.event_mapper_gt_fallback('tickpick_orders', true);
      PERFORM public.event_mapper_gt_fallback('sg_events_canonical', true);
      PERFORM public.tickets_dev_search_enqueue('s4kcs_orders', 60);
      PERFORM public.tickets_dev_search_enqueue('sg_events_canonical', 60);
      PERFORM public.venue_xref_derive_by_id(true);
      PERFORM public.performer_xref_derive_from_events(true);
      -- mig 20260917000000: the linkers, last, in precedence order (see header)
      PERFORM public.s4kcs_link_gotickets(true);
      PERFORM public.s4kcs_link_marketplaces(true);
      PERFORM public.s4kcs_link_tickets_dev(true);
      PERFORM public.n2s_link_gotickets(true);
    END $b$; COMMIT;
  $body$);
END $cron$;
