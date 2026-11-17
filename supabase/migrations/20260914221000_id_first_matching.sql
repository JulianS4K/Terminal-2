-- Match by ID, not by name — and the SeatGeek date bug that finding exposed.
--
-- Every rule in event_mapper_resolve except rule 0 ultimately compares STRINGS. That was
-- unavoidable while the only id we held per row was the source's own event id. It is no longer:
-- mig 20260914220000 gave aq_event_map a tevo_venue_id on all 15,110 mapped rows and filled
-- canonical_external_ids with 1,270 venue and 1,411 performer linkages. When both sides publish
-- an id there is no reason to compare prose.
--
-- HOW THE SEATGEEK BUG WAS FOUND, because it is the useful part. The first parity run of the id
-- path against 2,895 already-mapped SeatGeek rows disagreed on 400 of them — 14%, far too high
-- to ship. It was not the id rule. 399 of those 400 existing mappings were on a DIFFERENT LOCAL
-- DAY than SeatGeek said, and the id rule's pick was on the right one in all 400. Measured over
-- the whole mapped book (8,888 rows): sg_events_canonical.sg_event_date equals the UTC date on
-- 8,868 of them (99.8%) and is ONE DAY AHEAD of the TEvo local day on 2,253 (25.3%) — every
-- evening US event. It is a UTC date wearing a local date's name: exactly the landmine
-- PROJECT_BIBLE §3 already records for tickpick_orders.event_date, on a surface nobody rechecked.
--
-- Consequences, both of which this migration fixes:
--   * RECALL. The surface handed that date to the resolver as local_date. Rule 1 (venue + same
--     local day) therefore could not fire on a quarter of the book, and since mig 20260912051500
--     rule 2 refuses a candidate on a different local day too, those rows fell through to the
--     weakest rules or declined outright.
--   * CORRECTNESS of what is already there. Spot-checking the disagreements one by one: Tame
--     Impala, Usher and Chris Brown, Megan Moroney and Noah Kahan are each mapped to the show the
--     night AFTER the one SeatGeek sold, and a Detroit Tigers game is mapped to "San Francisco
--     Giants at Chicago White Sox". Those are pre-existing wrong rows, NOT caused by this change
--     and NOT corrected by it — event_mapper_map_surface only ever touches rows where previous
--     IS NULL. Re-pointing them is an overwrite of existing data and therefore an operator call;
--     it is recorded in KANBAN A1-MAP-1 as pending, not done quietly here.
--
-- The fix for the date is SeatGeek's own field: raw_event_jsonb->>'datetime_local', present on
-- 8,270 of 8,298 raw rows. Day-accuracy against the mirror over the 5,712 mapped rows that carry
-- one: 3,375 (59%) using the column, 5,353 (94%) using the raw field.
--
-- WHAT THE ID PATH IS AND IS NOT WORTH. With the corrected date the disagreement rate falls from
-- 14% to 3.5%, and the residual disagreements still favour the id rule. But it closes very little
-- backlog: of 1,704 unmapped future non-parking SeatGeek rows, the id path can map 21. The
-- SeatGeek residue is the TEvo-absent bucket (1,794 rows want a TEvo search), not an id problem.
-- The id path buys correctness and speed on rows it can reach, not recall. Said plainly so nobody
-- expects a number it will not produce.

CREATE OR REPLACE FUNCTION public.event_mapper_resolve_by_id(
  p_source              text,
  p_source_venue_id     bigint,
  p_local_date          date,
  p_source_performer_id text DEFAULT NULL,
  p_name                text DEFAULT NULL)
RETURNS TABLE(tevo_event_id bigint, method text, score numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_src text; v_venue bigint; v_perf bigint; v_n int; v_id bigint;
BEGIN
  IF p_source_venue_id IS NULL OR p_local_date IS NULL THEN RETURN; END IF;

  -- p_name is NEVER used to match. It exists only for this guard, and the guard is not optional:
  -- a SeatGeek "Parking: Yankees vs Red Sox" row carries the SAME venue id and the SAME date as
  -- the game, so venue+day alone would bind every parking row to the event it is parking for —
  -- the exact failure PROJECT_BIBLE §3 records from the 188-order parking incident.
  IF p_name IS NOT NULL AND (p_name ~* '(parking|shuttle|tailgate)'
                          OR p_name ~* '\(Date TBD\)|If Necessary|TBD vs TBD') THEN
    RETURN;
  END IF;

  -- resolver source tokens vs data_sources.source_key
  v_src := CASE lower(coalesce(p_source, ''))
             WHEN 'vivid' THEN 'vividseats' WHEN 'sg' THEN 'seatgeek'
             WHEN 'tp'    THEN 'tickpick'   WHEN 'gt' THEN 'gotickets'
             ELSE lower(p_source) END;

  SELECT x.tevo_id INTO v_venue FROM public.canonical_external_ids x
   WHERE x.entity_kind = 'venue' AND x.source_key = v_src
     AND x.external_id = p_source_venue_id::text LIMIT 1;

  IF v_venue IS NULL THEN
    SELECT m.tevo_venue_id INTO v_venue FROM public.cross_source_venue_map m
     WHERE (v_src = 'seatgeek'  AND m.sg_venue_id        = p_source_venue_id)
        OR (v_src = 'tickpick'  AND m.tickpick_venue_id  = p_source_venue_id)
        OR (v_src = 'gotickets' AND m.gotickets_venue_id = p_source_venue_id)
     LIMIT 1;
  END IF;
  IF v_venue IS NULL THEN RETURN; END IF;

  IF p_source_performer_id IS NOT NULL THEN
    SELECT x.tevo_id INTO v_perf FROM public.canonical_external_ids x
     WHERE x.entity_kind = 'performer' AND x.source_key = v_src
       AND x.external_id = p_source_performer_id LIMIT 1;
  END IF;

  -- venue id + local day. One hit is the answer; more than one needs the performer id to break
  -- the tie, and if that does not leave exactly one we decline rather than guess.
  SELECT count(*), min(e.id) INTO v_n, v_id
    FROM public.events e
   WHERE e.venue_id = v_venue
     AND left(e.occurs_at_local, 10) = p_local_date::text
     AND coalesce(e.name, '') !~* '(parking|shuttle|tailgate)';

  IF v_n = 1 THEN
    tevo_event_id := v_id; method := 'id_venue_day'; score := 0.97; RETURN NEXT; RETURN;
  END IF;

  IF v_n > 1 AND v_perf IS NOT NULL THEN
    SELECT count(*), min(e.id) INTO v_n, v_id
      FROM public.events e
     WHERE e.venue_id = v_venue
       AND left(e.occurs_at_local, 10) = p_local_date::text
       AND coalesce(e.name, '') !~* '(parking|shuttle|tailgate)'
       AND (e.primary_performer_id = v_perf OR v_perf = ANY(coalesce(e.performer_ids, ARRAY[]::bigint[])));
    IF v_n = 1 THEN
      tevo_event_id := v_id; method := 'id_venue_performer_day'; score := 0.98; RETURN NEXT;
    END IF;
  END IF;
  RETURN;
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapper_resolve_by_id(text, bigint, date, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_resolve_by_id(text, bigint, date, text, text) TO service_role;

COMMENT ON FUNCTION public.event_mapper_resolve_by_id(text, bigint, date, text, text) IS
  'ID-first matching: source venue id (+ performer id to break ties) -> tevo_event_id, with NO name comparison. p_name is used only for the parking/TBD guard. Unique-or-decline (mig 20260914221000).';
CREATE OR REPLACE FUNCTION public.event_mapper_surface_sql(p_surface text, p_horizon_days int DEFAULT 180)
RETURNS TABLE(select_sql text, update_sql text, key_type text)
LANGUAGE plpgsql IMMUTABLE
AS $fn$
BEGIN
  -- select_sql yields: row_key, source, source_event_id, event_name, performer, venue_name, venue_city,
  --                    venue_state, local_date, event_time_utc, previous (current tevo), ord (recency),
  --                    source_venue_id (the source's own venue id when it publishes one — mig 20260911220000),
  --                    source_performer_id (the source's own performer id — mig 20260914220000; SeatGeek only today)
  -- update_sql takes $1 row_key (text, cast inside), $2 tevo, $3 method, $4 score; fill-only.
  CASE p_surface
    WHEN 'gotickets_purchases' THEN
      select_sql := $q$SELECT gt_purchase_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, event_name,
                              performers->0->>'name' AS performer, venue_name, venue_city, venue_state, event_time_local::date AS local_date,
                              event_time_utc, tevo_event_id AS previous, updated_at AS ord, venue_id AS source_venue_id, NULL::text AS source_performer_id FROM public.gotickets_purchases WHERE event_time_local IS NOT NULL$q$;
      update_sql := $q$UPDATE public.gotickets_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE gt_purchase_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'seatgeek_purchases' THEN
      select_sql := $q$SELECT order_id AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, event_name, NULL::text AS performer,
                              event_location AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_start::date AS local_date,
                              NULL::timestamptz AS event_time_utc, tevo_event_id AS previous, updated_at AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id FROM public.seatgeek_purchases WHERE event_start IS NOT NULL$q$;
      update_sql := $q$UPDATE public.seatgeek_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 's4kcs_orders' THEN
      select_sql := $q$SELECT s4k_order_id AS row_key, lower(source) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue_name, venue_city, venue_state, event_date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, coalesce(mapped_at, pulled_at) AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id FROM public.s4kcs_orders WHERE event_date >= current_date - 7$q$;
      update_sql := $q$UPDATE public.s4kcs_orders SET tevo_event_id = $2, map_method = $3, map_confidence = $4, mapped_at = now() WHERE s4k_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'n2s_items' THEN
      select_sql := $q$SELECT n2s_id::text AS row_key, lower(marketplace) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_dt::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, n2s_updated_at AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id FROM public.n2s_items WHERE NOT coalesce(is_terminal, false) AND event_dt IS NOT NULL$q$;
      update_sql := $q$UPDATE public.n2s_items SET tevo_event_id = $2, mapped_via = $3 WHERE n2s_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'tickpick_orders' THEN
      select_sql := $q$SELECT tp_order_id AS row_key, 'tickpick'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, CASE WHEN raw->'venue'->>'id' ~ '^[0-9]+$' THEN (raw->'venue'->>'id')::bigint END AS source_venue_id, NULL::text AS source_performer_id FROM public.tickpick_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.tickpick_orders SET tevo_event_id = $2, matched_via = $3, match_confidence = $4, matched_at = now() WHERE tp_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'vivid_orders' THEN
      -- mig 20260911230000: Vivid's raw payload carries BOTH a venue string and its own event id
      -- (productionId) on 100% of the book; the surface threw both away, so rules 0 and 1 could never
      -- fire here and only the weakest rule (name+day) ever hit. Now:
      --   source_event_id = productionId  → rule 0 identity through aq_event_map.vivid_event_id
      --                                     (the same column n2s_vivid_order_identity already uses)
      --   venue_name/city/state = raw 'venue' split on its " - City, ST" suffix, with &amp;
      --                           decoded ("AT&amp;T Stadium" never matched the mirror's
      --                           "AT&T Stadium"). The split is GREEDY (mig 20260914210000):
      --                           the generated suffix is always LAST, and 26 of 448 distinct
      --                           venue strings carry a " - " inside the venue name itself,
      --                           which a non-greedy split tore in half.
      --   event_time_utc = NULL, DELIBERATELY. vivid_orders.event_date stores the LOCAL wall time
      --     labelled +00 (the XML's <eventDate> verbatim), so handing it to rule 2 as a real instant
      --     put the ±24 h window 4–7 h off and picked the PREVIOUS evening's show: dry run 2026-09-11
      --     bound Hamilton 9/12 → the 9/11 performance and two Harry Potter dates the same way, plus
      --     a "Grounds Passes" row → "Session 8". Rule 2 stays off for Vivid until the venue timezone
      --     is applied to that column. Rule 4 anchors at local noon/19:00 as usual.
      select_sql := $q$SELECT vivid_order_id AS row_key, 'vivid'::text AS source,
                              CASE WHEN raw->>'productionId' ~ '^[0-9]+$' THEN (raw->>'productionId')::bigint END AS source_event_id,
                              event_name, NULL::text AS performer,
                              replace(coalesce((regexp_match(raw->>'venue', '^(.*)\s+-\s+[^,]+,\s*[A-Za-z]{2}$'))[1],
                                               nullif(trim(coalesce(raw->>'venue', '')), '')), '&amp;', '&') AS venue_name,
                              (regexp_match(raw->>'venue', '^.*\s+-\s+([^,]+),\s*[A-Za-z]{2}$'))[1] AS venue_city,
                              (regexp_match(raw->>'venue', '^.*\s+-\s+[^,]+,\s*([A-Za-z]{2})$'))[1] AS venue_state,
                              event_date::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id
                         FROM public.vivid_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.vivid_orders SET tevo_event_id = $2 WHERE vivid_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'gotickets_event' THEN
      select_sql := format($q$SELECT gt_event_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, name AS event_name, performer,
                              venue_name, venue_city, venue_state, NULL::date AS local_date, event_time_utc, tevo_event_id AS previous,
                              coalesce(mapped_at, updated_at) AS ord, NULL::bigint AS source_venue_id, NULL::text AS source_performer_id FROM public.gotickets_event
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
      -- mig 20260914220000: sg_event_date is a UTC DATE, not a local one — the same landmine
      -- PROJECT_BIBLE §3 already records for tickpick_orders.event_date, on a surface nobody
      -- had checked. Measured over 8,888 mapped rows: it equals the UTC date on 8,868 (99.8%)
      -- and is ONE DAY AHEAD of the TEvo local day on 2,253 (25.3%) — every evening US event.
      -- Handing that to the resolver as local_date meant rule 1 (venue + same local day) simply
      -- could not fire on a quarter of the book, and since mig 20260912051500 rule 2 refuses a
      -- different local day too, so those rows fell through to the weakest rules or declined.
      -- SeatGeek ships the real thing in the payload: raw_event_jsonb->>'datetime_local', present
      -- on 8,270 of 8,298 raw rows. Day-accuracy against the TEvo mirror over 5,712 mapped rows
      -- with a raw local time: 3,375 (59%) with the column, 5,353 (94%) with the raw field.
      -- source_performer_id is SeatGeek's own primary performer id, which canonical_external_ids
      -- now resolves to a tevo_performer_id — it is what breaks a venue+day tie WITHOUT a name.
      select_sql := $q$SELECT sg_event_id::text AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, sg_event_name AS event_name, NULL::text AS performer,
                              sg_venue_name AS venue_name, sg_venue_city AS venue_city, sg_venue_state AS venue_state,
                              coalesce(nullif(left(raw_event_jsonb->>'datetime_local', 10), '')::date, sg_event_date) AS local_date,
                              sg_datetime_utc AS event_time_utc,
                              tevo_event_id AS previous, coalesce(matched_at, updated_at) AS ord,
                              coalesce(sg_venue_id, CASE WHEN raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$' THEN (raw_event_jsonb->'venue'->>'id')::bigint END) AS source_venue_id,
                              (SELECT p->>'id' FROM jsonb_array_elements(coalesce(raw_event_jsonb->'performers', '[]'::jsonb)) p
                                WHERE p->>'primary' = 'true' AND p->>'id' ~ '^[0-9]+$' LIMIT 1) AS source_performer_id
                         FROM public.sg_events_canonical
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

-- ---------------------------------------------------------------- event_mapper_map_surface
-- ID first, name second. Only the LATERAL changes: event_mapper_resolve_by_id runs on every row,
-- and the name cascade runs ONLY where the id path declined — so a row with no usable ids takes
-- exactly the path it took before. This function still processes only rows where previous IS
-- NULL, so nothing already mapped is touched or overwritten by this change.
--
-- The full body is carried forward verbatim from prod; the diff is the _em_out CREATE TEMP TABLE.
CREATE OR REPLACE FUNCTION public.event_mapper_map_surface(p_surface text, p_apply boolean DEFAULT false, p_limit integer DEFAULT 500, p_keys text[] DEFAULT NULL::text[])
RETURNS TABLE(row_key text, previous bigint, tevo_event_id bigint, method text, score numeric, crossmap text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_sel text; v_upd text; v_n int; rr record; v_x text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT s.select_sql, s.update_sql INTO v_sel, v_upd FROM public.event_mapper_surface_sql(p_surface) s;
  IF p_surface = 'n2s_items' AND p_apply AND p_keys IS NULL THEN
    UPDATE public.n2s_items n SET tevo_event_id = o.tevo_event_id, mapped_via = 'n2s_crm_order_identity'
      FROM public.s4kcs_orders o
     WHERE o.s4k_order_id = n.n2s_order_key AND o.tevo_event_id IS NOT NULL AND n.tevo_event_id IS NULL AND NOT coalesce(n.is_terminal, false);
    UPDATE public.n2s_items n SET tevo_event_id = o.tevo_event_id, mapped_via = 'n2s_evo_order_identity'
      FROM public.evo_orders o
     WHERE n.s4k_source = 'EVO' AND o.evo_order_id::text = n.n2s_order_key AND o.tevo_event_id IS NOT NULL
       AND n.tevo_event_id IS NULL AND NOT coalesce(n.is_terminal, false);
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_gt_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(g.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.gotickets_sales gs ON gs.gt_sale_id::text = n2.order_number
              LEFT JOIN public.gotickets_event g ON g.gt_event_id = gs.gt_event_id
              LEFT JOIN public.aq_event_map a ON a.gotickets_event_id = gs.gt_event_id AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'GoTickets' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(g.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_vivid_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(o.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.vivid_orders o ON o.vivid_order_id = n2.order_number
              LEFT JOIN public.aq_event_map a ON o.raw->>'productionId' ~ '^[0-9]+$'
                                             AND a.vivid_event_id = (o.raw->>'productionId')::bigint AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'Vivid Seats' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(o.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
    UPDATE public.n2s_items n SET tevo_event_id = s.eid, mapped_via = 'n2s_sg_order_identity'
      FROM (SELECT n2.n2s_id, min(coalesce(o.tevo_event_id, c.tevo_event_id, a.tevo_event_id)) AS eid
              FROM public.n2s_items n2
              JOIN public.seatgeek_orders o ON o.sg_order_id = n2.order_number
              LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = o.sg_event_id AND c.tevo_event_id IS NOT NULL
              LEFT JOIN public.aq_event_map a ON a.sg_event_id = o.sg_event_id AND a.tevo_event_id IS NOT NULL
             WHERE n2.s4k_source = 'SeatGeek' AND n2.tevo_event_id IS NULL AND NOT coalesce(n2.is_terminal, false)
             GROUP BY n2.n2s_id HAVING count(DISTINCT coalesce(o.tevo_event_id, c.tevo_event_id, a.tevo_event_id)) = 1) s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
  END IF;
  DROP TABLE IF EXISTS _em_rows;
  IF p_keys IS NULL THEN
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.previous IS NULL ORDER BY q.ord DESC NULLS LAST, q.event_time_utc ASC NULLS LAST, q.local_date ASC NULLS LAST LIMIT %s',
                   v_sel, greatest(1, least(5000, p_limit)));
  ELSE
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.row_key = ANY($1)', v_sel) USING p_keys;
  END IF;
  DROP TABLE IF EXISTS _em_out;
  -- mig 20260914221000: ID first, name second.
  CREATE TEMP TABLE _em_out ON COMMIT DROP AS
  SELECT q.row_key, q.previous, q.source, q.source_event_id, q.event_name, q.performer, q.venue_name, q.local_date, q.source_venue_id,
         coalesce(rid.tevo_event_id, res.tevo_event_id) AS tevo,
         coalesce(rid.method, res.method) AS method,
         coalesce(rid.score, res.score) AS score,
         NULL::text AS crossmap
    FROM _em_rows q
    LEFT JOIN LATERAL public.event_mapper_resolve_by_id(q.source, q.source_venue_id, q.local_date,
                        q.source_performer_id, q.event_name) rid ON true
    LEFT JOIN LATERAL public.event_mapper_resolve(q.source, q.source_event_id, q.event_name, q.performer, q.venue_name,
                        q.venue_city, q.venue_state, q.local_date, q.event_time_utc, (p_keys IS NULL), 0.5, q.source_venue_id) res
           ON rid.tevo_event_id IS NULL;
  IF p_apply THEN
    FOR rr IN SELECT o.* FROM _em_out o WHERE o.tevo IS NOT NULL AND o.previous IS NULL LOOP
      EXECUTE v_upd USING rr.row_key, rr.tevo, rr.method, rr.score;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN
        v_x := public.event_mapper_apply(rr.source, rr.source_event_id, rr.tevo, rr.event_name, rr.venue_name, rr.local_date, rr.score, rr.performer, rr.source_venue_id);
        UPDATE _em_out o SET crossmap = coalesce(v_x, 'written') WHERE o.row_key = rr.row_key;
      END IF;
    END LOOP;
  END IF;
  RETURN QUERY SELECT o.row_key, o.previous, o.tevo, o.method, o.score, o.crossmap FROM _em_out o;
END $function$;

REVOKE ALL ON FUNCTION public.event_mapper_map_surface(text, boolean, integer, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_map_surface(text, boolean, integer, text[]) TO service_role;

-- ---------------------------------------------------------------- EVO -> all, outward
-- The inward mappers answer "which TEvo event is this marketplace row?". This answers the other
-- direction: "we know this TEvo event — what is it called on every other marketplace?". It needs
-- no matching, because the catalogue is keyed by marketplace id: hand it ANY id the hub already
-- holds and it returns the rest of the cluster, which tickets_dev_hub_backfill() writes onto that
-- same hub row. Selection is "already anchored but incomplete", so the answer cannot contradict
-- anything we believe — it can only add ids we lack. First live run found 5,044 such rows.
CREATE OR REPLACE FUNCTION public.tickets_dev_fill_outward(p_limit int DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_cap int; v_g int := 0; v_v int := 0; v_s int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  v_cap := greatest(1, least(500, coalesce(p_limit, 200)));

  DROP TABLE IF EXISTS _td_gap;
  CREATE TEMP TABLE _td_gap ON COMMIT DROP AS
  SELECT a.tevo_event_id, a.gotickets_event_id, a.vivid_event_id, a.sh_event_id, a.tm_event_id, a.event_date
    FROM public.aq_event_map a
   WHERE a.tevo_event_id IS NOT NULL
     AND a.event_date >= current_date - 1
     AND num_nonnulls(a.gotickets_event_id, a.vivid_event_id, a.sh_event_id, a.tm_event_id) BETWEEN 1 AND 3;

  SELECT public.tickets_dev_probe_enqueue('gotickets', array_agg(id)) INTO v_g FROM (
    SELECT DISTINCT gotickets_event_id::text AS id, min(event_date) AS d FROM _td_gap
     WHERE gotickets_event_id IS NOT NULL GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;
  SELECT public.tickets_dev_probe_enqueue('vividseats', array_agg(id)) INTO v_v FROM (
    SELECT DISTINCT vivid_event_id::text AS id, min(event_date) AS d FROM _td_gap
     WHERE vivid_event_id IS NOT NULL AND gotickets_event_id IS NULL GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;
  SELECT public.tickets_dev_probe_enqueue('stubhub', array_agg(id)) INTO v_s FROM (
    SELECT DISTINCT sh_event_id::text AS id, min(event_date) AS d FROM _td_gap
     WHERE sh_event_id IS NOT NULL AND gotickets_event_id IS NULL AND vivid_event_id IS NULL
     GROUP BY 1 ORDER BY 2 LIMIT v_cap) q;

  RETURN jsonb_build_object('gap_rows', (SELECT count(*) FROM _td_gap),
                            'enqueued', jsonb_build_object('gotickets', coalesce(v_g,0),
                                                           'vividseats', coalesce(v_v,0),
                                                           'stubhub', coalesce(v_s,0)));
END $fn$;

REVOKE ALL ON FUNCTION public.tickets_dev_fill_outward(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickets_dev_fill_outward(int) TO service_role;

COMMENT ON FUNCTION public.tickets_dev_fill_outward(int) IS
  'EVO -> all: probe tickets.dev with an id the hub already holds, to learn the sibling ids it does not. GET-only (RULE 2). Mig 20260914221000.';

-- ---------------------------------------------------------------- the read side
CREATE OR REPLACE VIEW public.v_event_id_spine AS
SELECT a.tevo_event_id, a.event_name, a.event_date, a.tevo_venue_id, a.tevo_performer_id,
       a.venue_short_id, a.performer_short_id,
       a.sg_event_id, a.gotickets_event_id, a.vivid_event_id, a.sh_event_id, a.tm_event_id, a.tp_event_id,
       m.sg_venue_id, m.gotickets_venue_id, m.tickpick_venue_id,
       (SELECT x.external_id FROM public.canonical_external_ids x
         WHERE x.entity_kind = 'performer' AND x.tevo_id = a.tevo_performer_id AND x.source_key = 'seatgeek')    AS sg_performer_id,
       (SELECT x.external_id FROM public.canonical_external_ids x
         WHERE x.entity_kind = 'performer' AND x.tevo_id = a.tevo_performer_id AND x.source_key = 'tickets_dev') AS tdev_performer_id,
       num_nonnulls(a.sg_event_id, a.gotickets_event_id, a.vivid_event_id,
                    a.sh_event_id, a.tm_event_id, a.tp_event_id) AS marketplaces_known
  FROM public.aq_event_map a
  LEFT JOIN public.cross_source_venue_map m ON m.tevo_venue_id = a.tevo_venue_id
 WHERE a.tevo_event_id IS NOT NULL;

REVOKE ALL ON public.v_event_id_spine FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_event_id_spine TO service_role;

COMMENT ON VIEW public.v_event_id_spine IS
  'One row per mapped event with every ID we hold for it — TEvo venue/performer, each marketplace event id, each marketplace venue/performer id. The ID-first join surface (mig 20260914221000).';

-- ---------------------------------------------------------------- the cron
-- ONE job, not five. The instance runs ~197 cron jobs against max_worker_processes=6 and is
-- already shedding startup slots (an operator-gated problem on the drift watchlist), so the five
-- things that keep the ID spine current run in a single transaction on one schedule rather than
-- each claiming its own worker.
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
      PERFORM public.venue_xref_derive_by_id(true);
      PERFORM public.performer_xref_derive_from_events(true);
    END $b$; COMMIT;$body$);
END $cron$;

