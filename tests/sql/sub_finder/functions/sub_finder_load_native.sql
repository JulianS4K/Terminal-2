CREATE OR REPLACE FUNCTION public.sub_finder_load_native(p_job_id uuid, p_max_age interval DEFAULT NULL::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_since timestamptz := CASE WHEN p_max_age IS NULL THEN '-infinity'::timestamptz ELSE now() - p_max_age END;
  v_n     integer;
BEGIN
  PERFORM public.sub_finder_scratch();
  INSERT INTO _sf_l
  SELECT 'evo', 'native', x.event_id, x.tevo_ticket_group_id::text, x.section, x.row, x.quantity,
         x.retail_price, x.splits::int[], x.pulled_at,
         'https://core.ticketevolution.com/buy/event/' || x.event_id || '/tickets/' || x.tevo_ticket_group_id, NULL,
         CASE WHEN x.view_type ~* '(obstruct|limited|partial|restricted)'
                OR x.public_notes ~* '(obstruct|limited view|partial view|restricted view)' THEN 'obstructed' END
  FROM public.n2s_evo_current x
  WHERE x.event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
    AND x.pulled_at >= v_since
    AND NOT coalesce(x.is_owned, false) AND NOT coalesce(x.is_ancillary, false)
  UNION ALL
  SELECT 'gotickets', 'native', x.tevo_event_id, x.gt_listing_id::text, x.section, x.row, x.quantity,
         x.all_in_price, x.splits::int[], x.pulled_at,
         'https://pro.gotickets.com/tickets/' || x.gt_event_id || '/?sortBy=price&sortDirection=asc', NULL,
         CASE WHEN x.notes ~* '(obstruct|limited view|partial view|restricted view)' THEN 'obstructed' END
  FROM public.n2s_gt_current x
  WHERE x.tevo_event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
    AND x.pulled_at >= v_since
  UNION ALL
  -- SeatGeek link: the stored event URL plus the listing's display id — both or neither
  -- (see mig 20260910310000: half a link is worse than none).
  SELECT 'seatgeek', 'native', x.tevo_event_id, x.sglid::text, x.section, x.row, x.quantity,
         x.retail_price_all_in,
         ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(x.splits) = 'array' THEN x.splits
                                                     ELSE '[]'::jsonb END)::int),
         x.pulled_at,
         coalesce(nullif(sg.sg_url, ''), 'https://seatgeek.com/e/events/' || x.sg_event_id)
           || CASE WHEN x.display_id IS NOT NULL THEN '#listing=' || x.display_id ELSE '' END, NULL,   -- 20261113230000
         CASE WHEN coalesce(x.has_limited_view, false) THEN 'obstructed' END
  FROM public.n2s_sg_current x
  LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = x.sg_event_id
  WHERE x.tevo_event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
    AND x.pulled_at >= v_since
    AND NOT coalesce(x.is_broker_owned, false);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  ANALYZE _sf_l;                                   -- no statistics on a fresh temp table (20261113220000)
  RETURN v_n;
END
$function$

