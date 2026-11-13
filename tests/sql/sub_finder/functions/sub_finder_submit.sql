CREATE OR REPLACE FUNCTION public.sub_finder_submit(p_key_id bigint, p_key_label text, p_orders jsonb, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config;
  v_job   uuid;
  v_n     integer;
  v_evs   bigint[];
  v_miss  jsonb;
  v_idem  text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT (p_key_id = ANY (c.key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF v_idem IS NOT NULL THEN
    SELECT job_id INTO v_job FROM public.sub_finder_job WHERE key_id = p_key_id AND idempotency_key = v_idem;
    IF FOUND THEN
      RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                        'created_at', j.created_at, 'replayed', true)
              FROM public.sub_finder_job j WHERE j.job_id = v_job);
    END IF;
  END IF;
  IF jsonb_typeof(p_orders) IS DISTINCT FROM 'array' OR jsonb_array_length(p_orders) = 0 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'orders must be a non-empty array');
  END IF;
  IF jsonb_array_length(p_orders) > c.max_orders_per_job THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', format('at most %s orders per job', c.max_orders_per_job));
  END IF;

  IF to_regclass('pg_temp._sf_in') IS NOT NULL THEN DROP TABLE _sf_in; END IF;
  CREATE TEMP TABLE _sf_in ON COMMIT DROP AS
  SELECT o.ord::int AS idx, btrim(o.j->>'order_number') AS order_number,
         coalesce(nullif(btrim(o.j->>'site'), ''), m.site)                 AS site,
         coalesce(nullif(btrim(o.j->>'section'), ''), m.section)           AS section,
         coalesce(nullif(btrim(o.j->>'row'), ''), m.seat_row)              AS seat_row,
         coalesce((o.j->>'qty')::int, m.qty)                               AS qty,
         coalesce((o.j->>'sold_ea')::numeric, m.sold_ea)                   AS sold_ea,
         (o.j->>'tevo_event_id')::bigint                                   AS sent_event,
         m.tevo_event_id                                                   AS book_event,
         coalesce(nullif(btrim(o.j->>'event_name'), ''), m.event_name)     AS event_name,
         coalesce((o.j->>'event_date')::date, m.event_date)                AS event_date,
         coalesce(nullif(btrim(o.j->>'venue'), ''), m.venue)               AS venue,
         coalesce(left(nullif(btrim(o.j->>'notes'), ''), 500),
                  (SELECT p.crm_notes FROM public.sub_finder_order p
                    WHERE p.key_id = p_key_id AND p.order_number = btrim(o.j->>'order_number')
                      AND p.crm_notes IS NOT NULL
                    ORDER BY p.updated_at DESC LIMIT 1))                     AS crm_notes,
         m.book
  FROM jsonb_array_elements(p_orders) WITH ORDINALITY o(j, ord)
  -- the marketplace's own order feed first, then our mirror of the CRM's books
  LEFT JOIN LATERAL public.sub_finder_lookup_best(btrim(o.j->>'order_number'), nullif(btrim(o.j->>'site'), '')) m ON true;

  SELECT jsonb_agg(order_number ORDER BY idx) INTO v_miss FROM _sf_in
   WHERE section IS NULL OR seat_row IS NULL OR qty IS NULL OR qty NOT BETWEEN 1 AND 50;
  SELECT count(*) INTO v_n FROM _sf_in
   WHERE section IS NOT NULL AND seat_row IS NOT NULL AND qty BETWEEN 1 AND 50;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('error', 'not_found', 'not_found', v_miss,
      'detail', 'none of these orders is in the CRM books we mirror; send section, row, qty and the event');
  END IF;

  INSERT INTO public.sub_finder_job (key_id, key_label, idempotency_key, order_count)
  VALUES (p_key_id, p_key_label, v_idem, v_n) RETURNING job_id INTO v_job;

  INSERT INTO public.sub_finder_order (job_id, idx, key_id, order_number, site, tevo_event_id, event_name,
                                       event_date, venue, section, seat_row, qty, sold_ea, state, order_source,
                                       crm_notes, crm_notes_at)
  SELECT v_job, i.idx, p_key_id, i.order_number, i.site, ev.id, coalesce(ev.name, i.event_name),
         coalesce(ev.occurs_at_local::date, i.event_date), i.venue, i.section, i.seat_row, i.qty, i.sold_ea,
         CASE WHEN ev.id IS NULL THEN 'unmapped' ELSE 'pending' END,
         coalesce(i.book, 'request'), i.crm_notes, CASE WHEN i.crm_notes IS NOT NULL THEN now() END
  FROM _sf_in i
  LEFT JOIN LATERAL (
    SELECT e.id, e.name, e.occurs_at_local
    FROM public.events e
    WHERE CASE WHEN i.sent_event IS NOT NULL THEN e.id = i.sent_event
               WHEN i.book_event IS NOT NULL THEN e.id = i.book_event
               ELSE lower(e.name) = lower(i.event_name) AND e.occurs_at_local::date = i.event_date
                    AND (SELECT count(*) FROM public.events e2
                         WHERE lower(e2.name) = lower(i.event_name)
                           AND e2.occurs_at_local::date = i.event_date) = 1
          END
    LIMIT 1) ev ON true
  WHERE i.section IS NOT NULL AND i.seat_row IS NOT NULL AND i.qty BETWEEN 1 AND 50;

  UPDATE public.sub_finder_order t
     SET in_n2s = true
   WHERE t.job_id = v_job AND EXISTS (SELECT 1 FROM public.n2s_items n
                                       WHERE n.order_number = t.order_number OR n.n2s_order_key = t.order_number);

  -- a new lookup of an order takes over: older lookups of it stop being refreshed
  UPDATE public.sub_finder_order o
     SET watching = false, closed_reason = 'superseded', closed_at = now()
   WHERE o.key_id = p_key_id AND o.watching AND o.job_id <> v_job
     AND o.order_number IN (SELECT n.order_number FROM public.sub_finder_order n WHERE n.job_id = v_job);
  -- nothing to refresh on an order with no event
  UPDATE public.sub_finder_order SET watching = false, closed_reason = 'unmapped', closed_at = now()
   WHERE job_id = v_job AND state = 'unmapped';

  -- Pull only the events the routine polling does not already have: one with EVO listings
  -- pulled within refresh_fresh is being polled (N2S does every open order's event, every
  -- market, about every 2 minutes), so its data is used as it stands.
  SELECT array_agg(DISTINCT o.tevo_event_id) INTO v_evs
  FROM public.sub_finder_order o
  WHERE o.job_id = v_job AND o.tevo_event_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.n2s_evo_current x
                    WHERE x.event_id = o.tevo_event_id AND x.pulled_at > now() - c.refresh_fresh);
  IF v_evs IS NOT NULL THEN
    PERFORM public.n2s_pull_events(v_evs, c.pull_refresh, true);   -- true: SeatGeek too, every time
  ELSE
    -- nothing to wait for: answer now (also closes a job whose orders are all unmapped)
    UPDATE public.sub_finder_job SET pulled = false WHERE job_id = v_job;
    IF NOT public.sub_finder_bg_settle() THEN     -- else the background job settles it (20261113260000)
      PERFORM public.sub_finder_settle(v_job);
    END IF;
  END IF;

  RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                    'created_at', j.created_at, 'replayed', false,
                                    'not_found', coalesce(v_miss, '[]'::jsonb),
                                    'unmapped', (SELECT count(*) FROM public.sub_finder_order o
                                                 WHERE o.job_id = v_job AND o.state = 'unmapped'))
          FROM public.sub_finder_job j WHERE j.job_id = v_job);
END
$function$

