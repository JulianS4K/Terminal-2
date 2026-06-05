-- ============================================================
-- Map our orders/sales to their tevo event (operator directive 2026-05-30:
-- "map all sales across to their respective events ... use the aq mapper";
-- follow-up: "use the tickpick event id to map against other tickpick event ids").
--
-- The terminal's order views (our_orders_by_event / unified_orders_by_event /
-- v3 cross_source_orders) key on tevo_event_id, which was NULL on most order rows.
-- backfill_order_tevo_from_aq() fills it via two reliable bridges:
--   1. AQ mapper (universal): orders already carry aq_short_event_id (set by
--      match_unmatched_orders_sweep); derive tevo from aq_event_map.tevo_event_id.
--      EVO is special: its native evo_order_items.event_id IS the TEvo id -> use directly.
--   2. TickPick fallback: for TP orders the AQ mapper couldn't resolve (e.g. ECF orders
--      whose aq rows were speculative/unlinked), use the TickPick event's own raw data —
--      the TP event_id groups them, and the event's local datetime + venue identify the
--      tevo event. UNIQUE-match only (HAVING count(*)=1) so it can never mis-map.
--
-- Idempotent; cron'd hourly @ :40 (after match_unmatched_orders_sweep_hourly @ :22).
-- Backfill results 2026-05-30: aq pass mapped 2,061 (TP 937 / Vivid 809 / EVO 315);
-- TP-event-id/date fallback mapped a further 649. Knicks ECF + Finals home games now
-- show full EVO + TickPick (+ Vivid) order coverage. SeatGeek orders are all 2018-2020
-- (no tevo-linked aq) so remain unmapped by design.
-- ============================================================
CREATE OR REPLACE FUNCTION public.backfill_order_tevo_from_aq()
RETURNS TABLE(tbl text, newly_mapped integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  UPDATE public.tickpick_orders o SET tevo_event_id = a.tevo_event_id
    FROM public.aq_event_map a
    WHERE a.aq_short_event_id = o.aq_short_event_id AND a.tevo_event_id IS NOT NULL AND o.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; tbl:='tickpick_orders (aq)'; newly_mapped:=n; RETURN NEXT;

  UPDATE public.vivid_orders o SET tevo_event_id = a.tevo_event_id
    FROM public.aq_event_map a
    WHERE a.aq_short_event_id = o.aq_short_event_id AND a.tevo_event_id IS NOT NULL AND o.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; tbl:='vivid_orders (aq)'; newly_mapped:=n; RETURN NEXT;

  UPDATE public.seatgeek_orders o SET tevo_event_id = a.tevo_event_id
    FROM public.aq_event_map a
    WHERE a.aq_short_event_id = o.aq_short_event_id AND a.tevo_event_id IS NOT NULL AND o.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; tbl:='seatgeek_orders (aq)'; newly_mapped:=n; RETURN NEXT;

  -- EVO: native evo_order_items.event_id IS the TEvo event id; use it directly (unambiguous orders).
  UPDATE public.evo_orders o SET tevo_event_id = sub.eid
    FROM (SELECT i.evo_order_id, min(i.event_id) AS eid
          FROM public.evo_order_items i WHERE i.event_id IS NOT NULL
          GROUP BY i.evo_order_id HAVING count(DISTINCT i.event_id) = 1) sub
    WHERE o.evo_order_id = sub.evo_order_id AND o.tevo_event_id IS NULL
      AND EXISTS (SELECT 1 FROM public.events e WHERE e.id = sub.eid);
  GET DIAGNOSTICS n = ROW_COUNT; tbl:='evo_orders (native id)'; newly_mapped:=n; RETURN NEXT;

  -- TickPick fallback: aq couldn't resolve -> match the TP event's own local datetime + venue
  -- to a UNIQUE tevo event (grouped per TP event via the order's raw).
  UPDATE public.tickpick_orders o SET tevo_event_id = c.tevo
    FROM (
      SELECT tp_order_id, max(eid) AS tevo
      FROM (
        SELECT o2.tp_order_id, e.id AS eid
        FROM public.tickpick_orders o2
        JOIN public.events e
          ON e.venue_name = (o2.raw->'venue'->>'name')
         AND left(e.occurs_at_local,19) = left(o2.raw->'event'->>'event_date',19)
        WHERE o2.tevo_event_id IS NULL AND (o2.raw->'venue'->>'name') IS NOT NULL
          AND (o2.raw->'event'->>'event_date') IS NOT NULL
      ) j
      GROUP BY tp_order_id HAVING count(*) = 1
    ) c
    WHERE o.tp_order_id = c.tp_order_id AND o.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; tbl:='tickpick_orders (tp-eventid/date)'; newly_mapped:=n; RETURN NEXT;
END $function$;

REVOKE ALL ON FUNCTION public.backfill_order_tevo_from_aq() FROM anon, PUBLIC;

-- Hourly at :40 (after match_unmatched_orders_sweep_hourly @ :22 sets aq_short_event_id).
DO $$ BEGIN PERFORM cron.unschedule('backfill-order-tevo-from-aq-hourly'); EXCEPTION WHEN OTHERS THEN NULL; END $$;
SELECT cron.schedule('backfill-order-tevo-from-aq-hourly', '40 * * * *',
  $cron$SELECT public.backfill_order_tevo_from_aq();$cron$);
