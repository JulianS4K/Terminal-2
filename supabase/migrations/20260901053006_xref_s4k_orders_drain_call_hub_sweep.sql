-- Migration 20260901053006 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_orders_drain_call_hub_sweep" (version 20260901053006) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

CREATE OR REPLACE FUNCTION public.s4k_orders_drain()
 RETURNS TABLE(request_id bigint, rows_seen integer, rows_upserted integer, note text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_temp'
AS $function$
DECLARE r RECORD; v_seen int; v_up int; v_note text; j jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 's4k_orders_drain: caller % not authorized', current_user;
  END IF;

  FOR r IN
    SELECT p.request_id, h.status_code, h.content
      FROM public.s4k_orders_pending p
      JOIN net._http_response h ON h.id = p.request_id
     WHERE p.resolved_at IS NULL
     ORDER BY p.fired_at
  LOOP
    v_seen := 0; v_up := 0; v_note := NULL; j := NULL;

    IF r.status_code <> 200 THEN
      v_note := format('HTTP %s', r.status_code);
    ELSE
      BEGIN
        j := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN
        j := NULL; v_note := 'unparseable body';
      END;
    END IF;

    IF j IS NOT NULL THEN
      SELECT count(*) INTO v_seen FROM jsonb_array_elements(j->'rows');

      WITH src AS (SELECT o FROM jsonb_array_elements(j->'rows') o)
      INSERT INTO public.s4k_marketplace_orders AS t
        (source, order_id, order_status, seller_status, event_name, event_date,
         venue_name, venue_city, venue_state, section, row_label, seats,
         quantity, price, delivery, inhand_date, payout_date, notes, purchase_date, raw)
      SELECT o->>'source', o->>'id',
             nullif(o->>'order_status',''), nullif(o->>'seller_status',''),
             nullif(o->>'event_name',''),
             (CASE WHEN o->>'event_date'    ~ '^\d{4}-\d{2}-\d{2}$' THEN (o->>'event_date')::date END),
             nullif(o->>'venue_name',''), nullif(o->>'venue_city',''), nullif(o->>'venue_state',''),
             nullif(o->>'section',''), nullif(o->>'row',''), nullif(o->>'seats',''),
             (CASE WHEN o->>'quantity' ~ '^-?\d+$'         THEN (o->>'quantity')::int END),
             (CASE WHEN o->>'price'    ~ '^-?\d+(\.\d+)?$' THEN (o->>'price')::numeric END),
             nullif(o->>'delivery',''),
             (CASE WHEN o->>'inhand_date'   ~ '^\d{4}-\d{2}-\d{2}$' THEN (o->>'inhand_date')::date END),
             (CASE WHEN o->>'payout_date'   ~ '^\d{4}-\d{2}-\d{2}$' THEN (o->>'payout_date')::date END),
             nullif(o->>'notes',''),
             (CASE WHEN o->>'purchase_date' ~ '^\d{4}-\d{2}-\d{2}$' THEN (o->>'purchase_date')::date END),
             o
        FROM src
       WHERE coalesce(o->>'source','') <> '' AND coalesce(o->>'id','') <> ''
      ON CONFLICT (source, order_id) DO UPDATE SET
        order_status = excluded.order_status, seller_status = excluded.seller_status,
        event_name = excluded.event_name, event_date = excluded.event_date,
        venue_name = excluded.venue_name, venue_city = excluded.venue_city,
        venue_state = excluded.venue_state, section = excluded.section,
        row_label = excluded.row_label, seats = excluded.seats,
        quantity = excluded.quantity, price = excluded.price,
        delivery = excluded.delivery, inhand_date = excluded.inhand_date,
        payout_date = excluded.payout_date, notes = excluded.notes,
        purchase_date = excluded.purchase_date, raw = excluded.raw,
        last_seen_at = now();
      GET DIAGNOSTICS v_up = ROW_COUNT;

      IF jsonb_array_length(coalesce(j->'errors','[]'::jsonb)) > 0 THEN
        v_note := 'upstream errors: ' || (j->'errors')::text;
      END IF;
    END IF;

    UPDATE public.s4k_orders_pending
       SET resolved_at = now(), rows_seen = v_seen, rows_upserted = v_up, note = v_note
     WHERE public.s4k_orders_pending.request_id = r.request_id;

    request_id := r.request_id; rows_seen := v_seen;
    rows_upserted := v_up; note := v_note; RETURN NEXT;
  END LOOP;

  -- 2026-09-01: was PERFORM public.s4k_orders_map_events(20000). That function
  -- was dropped by 20260831223945 when S4K was conformed to the AQ hub (the
  -- bespoke name/date mapper is the PROJECT_BIBLE §0 anti-pattern), but this
  -- caller was not updated, so every drain raised 42883 and rolled back its own
  -- upserts. Replaced with the canonical hub sweep. p_create_synthetic := false
  -- per the operator's "stamp only, no synthetics" decision of 2026-08-31.
  PERFORM public.s4k_orders_match_sweep(20000, false);
END $function$;

REVOKE ALL ON FUNCTION public.s4k_orders_drain() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4k_orders_drain() TO service_role;
;
