-- Migration 20260831225045 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_backfill_order_tevo_add_s4k" (version 20260831225045) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831260800 — backfill_order_tevo_from_aq: add the S4K block
-- Lane:     xref+macro
-- Touches:  s4k_marketplace_orders (W), tickpick_orders (W), vivid_orders (W),
--           seatgeek_orders (W), evo_orders (W), aq_event_map (R)
-- Pre-reqs: 20260831260700
--
-- Stage 3 of the canonical orders->tevo chain (PROJECT_BIBLE §5, cron :40).
-- The five existing blocks are unchanged; this appends s4k_marketplace_orders
-- so its tevo_event_id is DERIVED from the hub key rather than written by a
-- matcher of its own -- which is the whole point of conforming S4K to the hub
-- pattern in 20260831260000.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.backfill_order_tevo_from_aq()
 RETURNS TABLE(tbl text, newly_mapped integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

  UPDATE public.evo_orders o SET tevo_event_id = sub.eid
    FROM (SELECT i.evo_order_id, min(i.event_id) AS eid
          FROM public.evo_order_items i WHERE i.event_id IS NOT NULL
          GROUP BY i.evo_order_id HAVING count(DISTINCT i.event_id) = 1) sub
    WHERE o.evo_order_id = sub.evo_order_id AND o.tevo_event_id IS NULL
      AND EXISTS (SELECT 1 FROM public.events e WHERE e.id = sub.eid);
  GET DIAGNOSTICS n = ROW_COUNT; tbl:='evo_orders (native id)'; newly_mapped:=n; RETURN NEXT;

  -- TickPick fallback: aq couldn't resolve -> match the TP event's own local datetime + venue
  -- to a UNIQUE tevo event (grouped by the TP event id via the order's raw).
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

  -- S4K marketplace orders (added 2026-08-31): hub key -> canonical tevo id.
  UPDATE public.s4k_marketplace_orders o SET tevo_event_id = a.tevo_event_id
    FROM public.aq_event_map a
    WHERE a.aq_short_event_id = o.aq_short_event_id AND a.tevo_event_id IS NOT NULL AND o.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; tbl:='s4k_marketplace_orders (aq)'; newly_mapped:=n; RETURN NEXT;
END $function$;
;
