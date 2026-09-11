-- ============================================================================
-- Migration 20260911219000 — gotickets_event live selector: venue-known rows only, soonest first, per-surface live cap
-- Migration 20260911219000 · level:data-collection · lane:A1 · writes:event_mapper_switch
--
-- Lane:     A1 (data plane)
-- Touches:  event_mapper_switch (NEW column live_cap), event_mapper_surface_sql() (REPLACE — gotickets_event select),
--           event_mapper_map_surface() (REPLACE — tie-break soonest event first), event_mapper_run() (REPLACE — reads live_cap)
-- Pre-reqs: 20260911218000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction (same session).
--
-- First live gotickets_event run mapped 0 of 400: the catalogue has 138k future AS_SCHEDULED rows, all
-- refreshed in the same 5-minute window each morning, so "newest 400 unmapped" is an arbitrary slice
-- and it landed on bars and lounges TEvo never lists (0 of the 400 had ANY mirror event at that venue).
-- The gotickets_event select now keeps only rows whose venue the future mirror (989 names) or the
-- venue map (1,342 rows + GoTickets aliases) knows, the row order breaks ties by soonest event, and
-- the live cap is per surface (gotickets_event 1500 at ~30 ms/row ≈ 45 s; every other surface 400).
--
-- ROLLBACK: re-apply event_mapper_surface_sql + event_mapper_map_surface from 20260911210000 and
--           event_mapper_run from 20260911217000; ALTER TABLE public.event_mapper_switch DROP COLUMN live_cap;
-- ============================================================================

ALTER TABLE public.event_mapper_switch ADD COLUMN IF NOT EXISTS live_cap int NOT NULL DEFAULT 400;
COMMENT ON COLUMN public.event_mapper_switch.live_cap IS
  'live mode: how many unmapped rows one event_mapper_run() pass resolves (default 400; gotickets_event 1500). mig 20260911219000';
UPDATE public.event_mapper_switch SET live_cap = 1500 WHERE surface = 'gotickets_event';

CREATE OR REPLACE FUNCTION public.event_mapper_surface_sql(p_surface text, p_horizon_days int DEFAULT 180)
RETURNS TABLE(select_sql text, update_sql text, key_type text)
LANGUAGE plpgsql IMMUTABLE
AS $fn$
BEGIN
  -- select_sql yields: row_key, source, source_event_id, event_name, performer, venue_name, venue_city,
  --                    venue_state, local_date, event_time_utc, previous (current tevo), ord (recency)
  -- update_sql takes $1 row_key (text, cast inside), $2 tevo, $3 method, $4 score; fill-only.
  CASE p_surface
    WHEN 'gotickets_purchases' THEN
      select_sql := $q$SELECT gt_purchase_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, event_name,
                              performers->0->>'name' AS performer, venue_name, venue_city, venue_state, event_time_local::date AS local_date,
                              event_time_utc, tevo_event_id AS previous, updated_at AS ord FROM public.gotickets_purchases WHERE event_time_local IS NOT NULL$q$;
      update_sql := $q$UPDATE public.gotickets_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE gt_purchase_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'seatgeek_purchases' THEN
      select_sql := $q$SELECT order_id AS row_key, 'seatgeek'::text AS source, sg_event_id AS source_event_id, event_name, NULL::text AS performer,
                              event_location AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_start::date AS local_date,
                              NULL::timestamptz AS event_time_utc, tevo_event_id AS previous, updated_at AS ord FROM public.seatgeek_purchases WHERE event_start IS NOT NULL$q$;
      update_sql := $q$UPDATE public.seatgeek_purchases SET tevo_event_id = $2, mapped_via = $3, map_score = $4, updated_at = now() WHERE order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 's4kcs_orders' THEN
      select_sql := $q$SELECT s4k_order_id AS row_key, lower(source) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue_name, venue_city, venue_state, event_date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, coalesce(mapped_at, pulled_at) AS ord FROM public.s4kcs_orders WHERE event_date >= current_date - 7$q$;
      update_sql := $q$UPDATE public.s4kcs_orders SET tevo_event_id = $2, map_method = $3, map_confidence = $4, mapped_at = now() WHERE s4k_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'n2s_items' THEN
      select_sql := $q$SELECT n2s_id::text AS row_key, lower(marketplace) AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              venue AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_dt::date AS local_date, NULL::timestamptz AS event_time_utc,
                              tevo_event_id AS previous, n2s_updated_at AS ord FROM public.n2s_items WHERE NOT coalesce(is_terminal, false) AND event_dt IS NOT NULL$q$;
      update_sql := $q$UPDATE public.n2s_items SET tevo_event_id = $2, mapped_via = $3 WHERE n2s_id = $1::bigint AND tevo_event_id IS NULL$q$;
    WHEN 'tickpick_orders' THEN
      select_sql := $q$SELECT tp_order_id AS row_key, 'tickpick'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord FROM public.tickpick_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.tickpick_orders SET tevo_event_id = $2, matched_via = $3, match_confidence = $4, matched_at = now() WHERE tp_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'vivid_orders' THEN
      select_sql := $q$SELECT vivid_order_id AS row_key, 'vivid'::text AS source, NULL::bigint AS source_event_id, event_name, NULL::text AS performer,
                              NULL::text AS venue_name, NULL::text AS venue_city, NULL::text AS venue_state, event_date::date AS local_date, event_date AS event_time_utc,
                              tevo_event_id AS previous, ordered_at AS ord FROM public.vivid_orders WHERE event_date >= now() - interval '90 days'$q$;
      update_sql := $q$UPDATE public.vivid_orders SET tevo_event_id = $2 WHERE vivid_order_id = $1 AND tevo_event_id IS NULL$q$;
    WHEN 'gotickets_event' THEN
      select_sql := format($q$SELECT gt_event_id::text AS row_key, 'gotickets'::text AS source, gt_event_id AS source_event_id, name AS event_name, performer,
                              venue_name, venue_city, venue_state, NULL::date AS local_date, event_time_utc, tevo_event_id AS previous,
                              coalesce(mapped_at, updated_at) AS ord FROM public.gotickets_event
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
                              tevo_event_id AS previous, coalesce(matched_at, updated_at) AS ord FROM public.sg_events_canonical
                        WHERE sg_event_date >= current_date AND coalesce(sg_category, '') NOT IN ('Parking', 'parking')$q$;
      update_sql := $q$UPDATE public.sg_events_canonical SET tevo_event_id = $2, match_method = $3, match_confidence = $4, matched_at = now(), updated_at = now() WHERE sg_event_id = $1::bigint AND tevo_event_id IS NULL$q$;
    ELSE
      RAISE EXCEPTION 'event_mapper: unknown surface % (gotickets_purchases | seatgeek_purchases | s4kcs_orders | n2s_items | tickpick_orders | vivid_orders | gotickets_event | sg_events_canonical)', p_surface;
  END CASE;
  key_type := 'text';
  RETURN NEXT;
END $fn$;

CREATE OR REPLACE FUNCTION public.event_mapper_map_surface(
  p_surface text, p_apply boolean DEFAULT false, p_limit int DEFAULT 500, p_keys text[] DEFAULT NULL
)
RETURNS TABLE(row_key text, previous bigint, tevo_event_id bigint, method text, score numeric, crossmap text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_sel text; v_upd text; v_n int; rr record; v_x text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT s.select_sql, s.update_sql INTO v_sel, v_upd FROM public.event_mapper_surface_sql(p_surface) s;

  -- N2S identity rules 0–0e (verbatim from n2s_map_events): the SAME ORDER in one of our books.
  -- Identity beats inference, so they run before the resolver and only in apply mode.
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

  -- Candidate rows: unmapped (normal) or an explicit key set (shadow replay), newest first.
  DROP TABLE IF EXISTS _em_rows;
  IF p_keys IS NULL THEN
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.previous IS NULL ORDER BY q.ord DESC NULLS LAST, q.event_time_utc ASC NULLS LAST, q.local_date ASC NULLS LAST LIMIT %s',
                   v_sel, greatest(1, least(5000, p_limit)));
  ELSE
    EXECUTE format('CREATE TEMP TABLE _em_rows ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.row_key = ANY($1)', v_sel) USING p_keys;
  END IF;

  DROP TABLE IF EXISTS _em_out;
  CREATE TEMP TABLE _em_out ON COMMIT DROP AS
  SELECT q.row_key, q.previous, q.source, q.source_event_id, q.event_name, q.performer, q.venue_name, q.local_date,
         res.tevo_event_id AS tevo, res.method, res.score, NULL::text AS crossmap
    FROM _em_rows q
    LEFT JOIN LATERAL public.event_mapper_resolve(q.source, q.source_event_id, q.event_name, q.performer, q.venue_name,
                        q.venue_city, q.venue_state, q.local_date, q.event_time_utc, (p_keys IS NULL), 0.5) res ON true;

  IF p_apply THEN
    FOR rr IN SELECT o.* FROM _em_out o WHERE o.tevo IS NOT NULL AND o.previous IS NULL LOOP
      EXECUTE v_upd USING rr.row_key, rr.tevo, rr.method, rr.score;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN
        v_x := public.event_mapper_apply(rr.source, rr.source_event_id, rr.tevo, rr.event_name, rr.venue_name, rr.local_date, rr.score, rr.performer);
        UPDATE _em_out o SET crossmap = coalesce(v_x, 'written') WHERE o.row_key = rr.row_key;
      END IF;
    END LOOP;
  END IF;

  RETURN QUERY SELECT o.row_key, o.previous, o.tevo, o.method, o.score, o.crossmap FROM _em_out o;
END $fn$;

CREATE OR REPLACE FUNCTION public.event_mapper_run(p_surface text, p_horizon_days int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_mode text; v_fallback boolean := false; v_cap int; v_legacy jsonb := NULL; v_n int := 0; v_by jsonb := '{}'::jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT s.mode, s.live_fallback, s.live_cap INTO v_mode, v_fallback, v_cap FROM public.event_mapper_switch s WHERE s.surface = p_surface;
  v_mode := coalesce(v_mode, 'shadow');

  IF v_mode = 'live' THEN
    -- resolver first: bounded to the 400 newest unmapped rows per run (a 10-min / hourly cadence
    -- drains any backlog); writes fill-only + cross-maps (event_mapper_apply)
    SELECT count(*), coalesce(jsonb_object_agg(x.method, x.n), '{}'::jsonb) INTO v_n, v_by
      FROM (SELECT m.method, count(*) AS n FROM public.event_mapper_map_surface(p_surface, true, coalesce(v_cap, 400)) m
             WHERE m.tevo_event_id IS NOT NULL GROUP BY m.method) x;
    IF NOT v_fallback THEN
      RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n, 'by', v_by);
    END IF;
  END IF;

  -- legacy mapper: the whole job in legacy / shadow mode; the fill-only fallback for rows the
  -- resolver left NULL in live mode (mig 20260911217000). The shadow replay lives in
  -- event_mapper_shadow_tick(), which every cron calls in its OWN transaction, so a slow replay can
  -- never roll back a legacy write (2026-09-11 18:16: a 2000-key replay hit the 170 s cap and undid
  -- s4kcs_map_events' writes).
  CASE p_surface
    WHEN 's4kcs_orders'        THEN SELECT jsonb_agg(to_jsonb(t)) INTO v_legacy FROM public.s4kcs_map_events() t;
    WHEN 'n2s_items'           THEN SELECT jsonb_agg(to_jsonb(t)) INTO v_legacy FROM public.n2s_map_events(true) t;
    WHEN 'gotickets_event'     THEN
      v_legacy := jsonb_build_object('gt_map_events', public.gt_map_events(coalesce(p_horizon_days, 120)));
      IF p_horizon_days IS NOT NULL AND p_horizon_days > 180 THEN
        SELECT v_legacy || jsonb_build_object('match_gotickets_us_events', to_jsonb(t)) INTO v_legacy FROM public.match_gotickets_us_events(3000, p_horizon_days, 0.80, true) t;
      ELSE
        SELECT v_legacy || jsonb_build_object('match_gotickets_us_events', to_jsonb(t)) INTO v_legacy FROM public.match_gotickets_us_events(1500, 180, 0.80, true) t;
      END IF;
    WHEN 'sg_events_canonical' THEN SELECT to_jsonb(t) INTO v_legacy FROM public.auto_match_sg_canonical_v3() t;
    ELSE v_legacy := jsonb_build_object('legacy', 'none (AQ sweep :22 / backfill :40 own this surface)');
  END CASE;

  IF v_mode = 'live' THEN
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n, 'by', v_by, 'legacy_fallback', v_legacy);
  END IF;
  RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'legacy', v_legacy,
                            'shadow', 'see event_mapper_shadow_tick(surface) - separate transaction');
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapper_surface_sql(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_surface_sql(text, int) TO service_role;
REVOKE ALL ON FUNCTION public.event_mapper_map_surface(text, boolean, int, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_map_surface(text, boolean, int, text[]) TO service_role;
REVOKE ALL ON FUNCTION public.event_mapper_run(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_run(text, int) TO service_role;
COMMENT ON FUNCTION public.event_mapper_run(text, int) IS
  'The ONE mapper entry point every cron calls. Dispatches on event_mapper_switch.mode: legacy / shadow → old mapper only (the dry run is event_mapper_shadow_tick, own transaction); live → resolver writes + cross-maps (live_cap rows), then the old mapper as a fill-only fallback when live_fallback is on. A1 mig 20260911210000; reshaped 215000; live fallback 217000; per-surface live_cap 219000.';
