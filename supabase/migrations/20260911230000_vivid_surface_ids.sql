-- ============================================================================
-- Migration 20260911230000 — vivid_orders surface: pass Vivid's production id and venue string through to the mapper
-- Migration 20260911230000 · level:data-collection · lane:A1 · writes:none (function REPLACE) · reads:vivid_orders
--
-- Lane:     A1 (data plane)
-- Touches:  event_mapper_surface_sql() (REPLACE — identical to mig 20260911220000 except the vivid_orders branch)
-- Pre-reqs: 20260911220000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction (found while diagnosing why
-- Vivid order 81442598 never mapped).
--
-- The vivid_orders select discarded every identifying field Vivid gives us: source_event_id, venue_name,
-- venue_city and venue_state were all hard-coded NULL. With no venue the resolver could not run rule 1
-- (venue + local day) or rule 2 at all, and with no source id rule 0 identity could never fire — the
-- surface was left with rule 3 (exact name + day, score 0.70) and rule 4. Meanwhile all 7,585 rows in
-- the 90-day window carry a venue string AND a productionId, and 1,614 distinct productionIds already
-- sit on an aq_event_map row that carries a tevo id.
--
-- DRY RUN on prod, 400 newest unmapped rows, old inputs vs new (2026-09-11 ~21:30 UTC):
--     agree (same tevo id) 127 · DISAGREE 0 · LOST 0 · GAINED 27 (identity_hub 6, venue_day_name 21)
--   Strictly additive: every row the old inputs mapped, the new inputs map to the SAME event, and the
--   gained rows arrive by STRONGER methods. Full new distribution over those 400: identity_hub 40,
--   venue_day_name 110, name_day_exact 4, declined 246 — and 0 picks land on a different local day.
--   (name_day_exact falls 127 → 4 because rules 0 and 1 now claim those rows first, at higher scores.)
--
-- vivid_orders is still mode='shadow' with no cron caller, so this changes nothing until it is flipped;
-- it is what makes flipping it worth doing.
--
-- ROLLBACK: re-apply event_mapper_surface_sql from 20260911220000.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.event_mapper_surface_sql(p_surface text, p_horizon_days int DEFAULT 180)
RETURNS TABLE(select_sql text, update_sql text, key_type text)
LANGUAGE plpgsql IMMUTABLE
AS $fn$
BEGIN
  -- select_sql yields: row_key, source, source_event_id, event_name, performer, venue_name, venue_city,
  --                    venue_state, local_date, event_time_utc, previous (current tevo), ord (recency),
  --                    source_venue_id (the source's own venue id when it publishes one — mig 20260911220000)
  -- update_sql takes $1 row_key (text, cast inside), $2 tevo, $3 method, $4 score; fill-only.
  CASE p_surface
    WHEN 'gotickets_purchases' THEN
      select_sql := $q$SELECT gt_purchase_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, event_name,
                              performers->0->>'name' AS performer, venue_name, venue_city, venue_state, event_time_local::date AS local_date,
                              event_time_utc, tevo_event_id AS previous, updated_at AS ord, venue_id AS source_venue_id FROM public.gotickets_purchases WHERE event_time_local IS NOT NULL$q$;
      update_sql := $q$UPDATE public.gotickets_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE gt_purchase_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'seatgeek_purchases' THEN
      select_sql := $q$SELECT order_id AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, event_name, NULL::text AS performer,
                              event_location AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_start::date AS local_date,
                              NULL::timestamptz AS event_time_utc, tevo_event_id AS previous, updated_at AS ord, NULL::bigint AS source_venue_id FROM public.seatgeek_purchases WHERE event_start IS NOT NULL$q$;
      update_sql := $q$UPDATE public.seatgeek_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 's4kcs_orders' THEN
      select_sql := $q$SELECT s4k_order_id AS row_key, lower(source) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue_name, venue_city, venue_state, event_date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, coalesce(mapped_at, pulled_at) AS ord, NULL::bigint AS source_venue_id FROM public.s4kcs_orders WHERE event_date >= current_date - 7$q$;
      update_sql := $q$UPDATE public.s4kcs_orders SET tevo_event_id = $2, map_method = $3, map_confidence = $4, mapped_at = now() WHERE s4k_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'n2s_items' THEN
      select_sql := $q$SELECT n2s_id::text AS row_key, lower(marketplace) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_dt::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, n2s_updated_at AS ord, NULL::bigint AS source_venue_id FROM public.n2s_items WHERE NOT coalesce(is_terminal, false) AND event_dt IS NOT NULL$q$;
      update_sql := $q$UPDATE public.n2s_items SET tevo_event_id = $2, mapped_via = $3 WHERE n2s_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'tickpick_orders' THEN
      select_sql := $q$SELECT tp_order_id AS row_key, 'tickpick'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, CASE WHEN raw->'venue'->>'id' ~ '^[0-9]+$' THEN (raw->'venue'->>'id')::bigint END AS source_venue_id FROM public.tickpick_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.tickpick_orders SET tevo_event_id = $2, matched_via = $3, match_confidence = $4, matched_at = now() WHERE tp_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'vivid_orders' THEN
      -- mig 20260911230000: Vivid's raw payload carries BOTH a venue string and its own event id
      -- (productionId) on 100% of the book; the surface threw both away, so rules 0 and 1 could never
      -- fire here and only the weakest rule (name+day) ever hit. Now:
      --   source_event_id = productionId  → rule 0 identity through aq_event_map.vivid_event_id
      --                                     (the same column n2s_vivid_order_identity already uses)
      --   venue_name/city/state = raw 'venue' split on its " - City, ST" suffix (378 of 379 distinct
      --                           strings split; the rest fall back whole) with &amp; decoded
      --                           ("AT&amp;T Stadium" never matched the mirror's "AT&T Stadium")
      --   event_time_utc = NULL, DELIBERATELY. vivid_orders.event_date stores the LOCAL wall time
      --     labelled +00 (the XML's <eventDate> verbatim), so handing it to rule 2 as a real instant
      --     put the ±24 h window 4–7 h off and picked the PREVIOUS evening's show: dry run 2026-09-11
      --     bound Hamilton 9/12 → the 9/11 performance and two Harry Potter dates the same way, plus
      --     a "Grounds Passes" row → "Session 8". Rule 2 stays off for Vivid until the venue timezone
      --     is applied to that column. Rule 4 anchors at local noon/19:00 as usual.
      select_sql := $q$SELECT vivid_order_id AS row_key, 'vivid'::text AS source,
                              CASE WHEN raw->>'productionId' ~ '^[0-9]+$' THEN (raw->>'productionId')::bigint END AS source_event_id,
                              event_name, NULL::text AS performer,
                              replace(coalesce((regexp_match(raw->>'venue', '^(.*?)\s+-\s+[^,]+,\s*[A-Za-z]{2}$'))[1],
                                               nullif(trim(coalesce(raw->>'venue', '')), '')), '&amp;', '&') AS venue_name,
                              (regexp_match(raw->>'venue', '^.*?\s+-\s+([^,]+),\s*[A-Za-z]{2}$'))[1] AS venue_city,
                              (regexp_match(raw->>'venue', '^.*?\s+-\s+[^,]+,\s*([A-Za-z]{2})$'))[1] AS venue_state,
                              event_date::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, NULL::bigint AS source_venue_id
                         FROM public.vivid_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.vivid_orders SET tevo_event_id = $2 WHERE vivid_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'gotickets_event' THEN
      select_sql := format($q$SELECT gt_event_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, name AS event_name, performer,
                              venue_name, venue_city, venue_state, NULL::date AS local_date, event_time_utc, tevo_event_id AS previous,
                              coalesce(mapped_at, updated_at) AS ord, NULL::bigint AS source_venue_id FROM public.gotickets_event
                        WHERE status = 'AS_SCHEDULED' AND event_time_utc > now() AND event_time_utc < now() + make_interval(days => %s)
                          -- mig 20260911219000: only rows whose venue the TEvo mirror (future events) or the venue map
                          -- already knows — 138k future catalogue rows, most at venues TEvo never lists (hashed IN-lists)
                          AND lower(trim(venue_name)) IN (
                                SELECT lower(trim(e.venue_name)) FROM public.events e
                                 WHERE left(e.occurs_at_local, 10) >= current_date::text AND e.venue_name IS NOT NULL
                                UNION SELECT lower(trim(m.tevo_venue_name)) FROM public.cross_source_venue_map m WHERE m.tevo_venue_name IS NOT NULL
                                UNION SELECT lower(trim(x)) FROM public.cross_source_venue_map m, jsonb_array_elements_text(m.gotickets_aliases) x
                                 WHERE jsonb_typeof(m.gotickets_aliases) = 'array')$q$,
                        greatest(1, coalesce(p_horizon_days, 180)));
      update_sql := $q$UPDATE public.gotickets_event SET tevo_event_id = $2, mapped_via = $3, map_score = $4, mapped_at = now(), updated_at = now() WHERE gt_event_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'sg_events_canonical' THEN
      select_sql := $q$SELECT sg_event_id::text AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, sg_event_name AS event_name, NULL::text AS performer,
                              sg_venue_name AS venue_name, sg_venue_city AS venue_city, sg_venue_state AS venue_state, sg_event_date AS local_date, sg_datetime_utc AS event_time_utc,
                              tevo_event_id AS previous, coalesce(matched_at, updated_at) AS ord,
                              coalesce(sg_venue_id, CASE WHEN raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$' THEN (raw_event_jsonb->'venue'->>'id')::bigint END) AS source_venue_id FROM public.sg_events_canonical
                        WHERE sg_event_date >= current_date AND coalesce(sg_category, '') NOT IN ('Parking', 'parking')$q$;
      update_sql := $q$UPDATE public.sg_events_canonical SET tevo_event_id = $2, match_method = $3, match_confidence = $4, matched_at = now(), updated_at = now() WHERE sg_event_id = $1::bigint AND tevo_event_id IS NULL$q$;
    ELSE
      RAISE EXCEPTION 'event_mapper: unknown surface % (gotickets_purchases | seatgeek_purchases | s4kcs_orders | n2s_items | tickpick_orders | vivid_orders | gotickets_event | sg_events_canonical)', p_surface;
  END CASE;
  key_type := 'text';
  RETURN NEXT;
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapper_surface_sql(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_surface_sql(text, int) TO service_role;
