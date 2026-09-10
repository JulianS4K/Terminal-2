-- ROLLBACK STEP 3b/2 — restore public.backfill_order_tevo_from_aq() verbatim to
-- its origin/main (e43d549) definition, from
-- supabase/migrations/20260530200000_backfill_order_tevo_from_aq.sql.
--
-- The branch overwrote it in 20260831225045 to add an s4k_marketplace_orders
-- pass; that table is now quarantined, so the pass has to go with it.

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
