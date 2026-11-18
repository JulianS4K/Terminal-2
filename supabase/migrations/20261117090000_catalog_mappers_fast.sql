-- Migration 20261117090000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tickpick_catalog_map() fn (plan fix),vivid_catalog_map() fn (plan fix + advisory lock),vivid_catalog_tick() fn (try-lock),cron:tickpick_catalog_hourly(ceiling),cron:vivid_catalog_map_hourly(ceiling) · reads:events · pre:20261117080000
--
-- MAPPING PROGRAM — THE CATALOGUE MAPPERS RUN INSIDE THEIR HOUR.
--
-- With the name+state venue pairing (mig 20261117080000) the two catalogue mappers see ten times the venues, and
-- both ran past their ceilings on 2026-11-17: the TickPick hourly took 127 s before the change, and both exceeded
-- 60 s by hand after it. EXPLAIN ANALYZE of the venue + day join against public.events: the planner used the
-- local-day index alone and filtered the venue afterwards — 377,255 rows removed by the join filter to keep 757
-- pairs on a 60-day window (7.7 s), scaling with every pair. public.events has no (venue_id, day) index, and adding
-- one is DDL on a table every poller reads. Instead each mapper now materialises the upcoming EVO events once per
-- run into a temp table indexed by (venue_id, local day) and joins that; the name rule is unchanged (sampled: the
-- "fits" it accepts are the same show under both names, e.g. "Little Shop Of Horrors" / "Little Shop of Horrors").
-- The two crons get a 300 s ceiling (from 150 s) so a slow hour degrades rather than fails. Bodies otherwise those
-- of mig 20261117080000 (generated from that file; only the marked block and the join line differ).
--
-- Also (2026-11-17 11:43Z, seen once the fit step fit the hour): vivid_catalog_map's UPDATE of vivid_catalog_event
-- deadlocked with the minute tick's upsert of the same table. The map now takes pg_advisory_xact_lock('vivid_catalog')
-- first and the tick (redefined from mig 20261117070000, one line added) tries the same lock and skips its minute
-- while the map holds it — never the other way round, so a 58 s tick cannot be left waiting on a 300 s map. And the
-- order fills (step 6, both mappers) look only at orders from yesterday on; the older book has nothing left to fill.
-- RULE 2: nothing upstream is called.

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.tickpick_catalog_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_out jsonb := '{}'::jsonb;
  v_n   int;
BEGIN
  -- 0. candidates: upcoming, dated, at venues in the US, Canada or Mexico (mig 20261117080000)
  DROP TABLE IF EXISTS _tc_cand;
  CREATE TEMP TABLE _tc_cand ON COMMIT DROP AS
  SELECT c.tp_event_id, c.name, c.performers, c.tp_venue_id, c.event_date, c.event_utc, c.time_confirmed,
         c.tevo_event_id AS cur_tevo, c.tevo_match_method AS cur_method
    FROM public.tickpick_catalog_event c
   WHERE c.status IS DISTINCT FROM 'canceled' AND c.merged_into IS NULL AND c.date_confirmed
     AND c.event_date BETWEEN current_date - 1 AND current_date + 400
     AND coalesce(c.venue_country, 'US') IN ('US', 'CA', 'MX');
  CREATE INDEX ON _tc_cand (tp_event_id);
  v_out := v_out || jsonb_build_object('candidates', (SELECT count(*) FROM _tc_cand));

  -- 1. verify the matched: still that event, on that day?
  DROP TABLE IF EXISTS _tc_drop;
  CREATE TEMP TABLE _tc_drop ON COMMIT DROP AS
  SELECT x.tp_event_id, x.cur_tevo, x.cur_method,
         CASE WHEN e.id IS NULL THEN 'event_gone'
              WHEN e.state = 'ignored' THEN 'event_ignored'
              ELSE 'day_moved' END AS why
    FROM _tc_cand x
    LEFT JOIN public.events e ON e.id = x.cur_tevo
   WHERE x.cur_tevo IS NOT NULL
     AND (e.id IS NULL OR e.state = 'ignored' OR left(e.occurs_at_local, 10) IS DISTINCT FROM to_char(x.event_date, 'YYYY-MM-DD'));
  v_out := v_out || jsonb_build_object('dropped', (SELECT count(*) FROM _tc_drop));
  IF p_apply THEN
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.tp_event_id, 'drop', 'tickpick_catalog_event', d.tp_event_id::text, d.cur_tevo, d.why || ' (' || coalesce(d.cur_method, '?') || ')' FROM _tc_drop d;
    UPDATE public.tickpick_catalog_event c SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL
      FROM _tc_drop d WHERE d.tp_event_id = c.tp_event_id;
  END IF;
  UPDATE _tc_cand x SET cur_tevo = NULL, cur_method = NULL FROM _tc_drop d WHERE d.tp_event_id = x.tp_event_id;

  DROP TABLE IF EXISTS _tc_pick;
  CREATE TEMP TABLE _tc_pick (tp_event_id bigint PRIMARY KEY, tevo_event_id bigint NOT NULL, method text NOT NULL) ON COMMIT DROP;

  -- 2. identity: the hub's tp_event_id; our own orders already mapped — same local day AND the name still fits
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT DISTINCT ON (x.tp_event_id) x.tp_event_id, a.tevo_event_id, 'hub_identity'
    FROM _tc_cand x
    JOIN public.aq_event_map a ON a.tp_event_id = x.tp_event_id AND a.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = a.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
   ORDER BY x.tp_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT x.tp_event_id, o.tevo, 'order_identity'
    FROM _tc_cand x
    JOIN (SELECT (o.raw->'event'->>'event_id')::bigint AS tp, o.tevo_event_id AS tevo, count(*) AS n
            FROM public.tickpick_orders o
           WHERE o.tevo_event_id IS NOT NULL AND (o.raw->'event'->>'event_id') ~ '^\d+$'
           GROUP BY 1, 2) o ON o.tp = x.tp_event_id
    JOIN public.events e ON e.id = o.tevo AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
     AND NOT EXISTS (SELECT 1 FROM public.tickpick_orders o2
                      WHERE (o2.raw->'event'->>'event_id') ~ '^\d+$' AND (o2.raw->'event'->>'event_id')::bigint = x.tp_event_id
                        AND o2.tevo_event_id IS NOT NULL AND o2.tevo_event_id <> o.tevo)
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object('identity', (SELECT count(*) FROM _tc_pick));

  -- 3. venues: manual -> aq_venue_map -> cross_source (unanimous) -> name + state (mig 20261117080000) -> learned
  DROP TABLE IF EXISTS _cat_tv;
  CREATE TEMP TABLE _cat_tv ON COMMIT DROP AS SELECT * FROM public.catalog_tevo_venues_by_name();
  CREATE INDEX ON _cat_tv (nm, st);
  DROP TABLE IF EXISTS _tc_venue;
  CREATE TEMP TABLE _tc_venue ON COMMIT DROP AS
  WITH known AS (
    SELECT v.tp_venue_id, v.tevo_venue_id, 'manual' AS method, 1 AS pri
      FROM public.tickpick_catalog_venue v WHERE v.method = 'manual' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT m.tickpick_venue_id, m.tevo_venue_id, 'aq_venue_map', 2
      FROM public.aq_venue_map m WHERE m.tickpick_venue_id IS NOT NULL AND m.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT c.tickpick_venue_id, min(c.tevo_venue_id), 'cross_source', 3
      FROM public.cross_source_venue_map c
     WHERE c.tickpick_venue_id IS NOT NULL AND c.tevo_venue_id IS NOT NULL
     GROUP BY c.tickpick_venue_id HAVING count(DISTINCT c.tevo_venue_id) = 1
    UNION ALL
    SELECT v.tp_venue_id, t.tevo_venue_id, 'name_state', 4
      FROM public.tickpick_catalog_venue v
      JOIN _cat_tv t ON t.nm = lower(trim(v.name)) AND t.st = upper(trim(v.state))
     WHERE coalesce(v.country, 'US') IN ('US', 'CA', 'MX') AND coalesce(v.state, '') <> ''
    UNION ALL
    SELECT s.tp_venue_id, s.tv, 'matched_events', 5
      FROM (SELECT x.tp_venue_id, e.venue_id AS tv, count(*) AS n,
                   row_number() OVER (PARTITION BY x.tp_venue_id ORDER BY count(*) DESC, e.venue_id) AS rn
              FROM _tc_cand x
              LEFT JOIN _tc_pick p ON p.tp_event_id = x.tp_event_id
              JOIN public.events e ON e.id = coalesce(p.tevo_event_id, x.cur_tevo)
             WHERE x.tp_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY x.tp_venue_id, e.venue_id) s
     WHERE s.rn = 1
  )
  SELECT DISTINCT ON (k.tp_venue_id) k.tp_venue_id, k.tevo_venue_id, k.method
    FROM known k ORDER BY k.tp_venue_id, k.pri;
  CREATE INDEX ON _tc_venue (tp_venue_id);
  v_out := v_out || jsonb_build_object('venues_resolved', (SELECT count(*) FROM _tc_venue),
                                       'venues_by_method', (SELECT coalesce(jsonb_object_agg(method, n), '{}'::jsonb) FROM (SELECT method, count(*) n FROM _tc_venue GROUP BY 1) s));

  -- 4a. the EVO events the fits can see, once: upcoming, not ignored, indexed by venue and local day
  --     (mig 20261117090000: joining public.events by venue + left(occurs_at_local, 10) made the planner walk every
  --      event of the day and filter the venue afterwards — 377k rows thrown away for 757 pairs on a 60-day window)
  DROP TABLE IF EXISTS _cat_ev;
  CREATE TEMP TABLE _cat_ev ON COMMIT DROP AS
  SELECT e.id, e.venue_id, left(e.occurs_at_local, 10) AS day, e.name, e.primary_performer_name, e.occurs_at_local
    FROM public.events e
   WHERE e.occurs_at_local >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
     AND e.state IS DISTINCT FROM 'ignored' AND e.venue_id IS NOT NULL;
  CREATE INDEX ON _cat_ev (venue_id, day);
  ANALYZE _cat_ev;

  -- 4. venue + local day (+ name, + time)
  DROP TABLE IF EXISTS _tc_fit;
  CREATE TEMP TABLE _tc_fit ON COMMIT DROP AS
  SELECT x.tp_event_id, e.id AS tevo_event_id, x.time_confirmed,
         (x.time_confirmed AND x.event_utc IS NOT NULL
          AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _tc_cand x
    JOIN _tc_venue v ON v.tp_venue_id = x.tp_venue_id
    JOIN _cat_ev e ON e.venue_id = v.tevo_venue_id AND e.day = to_char(x.event_date, 'YYYY-MM-DD')
   WHERE x.cur_tevo IS NULL
     AND NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = x.tp_event_id)
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name);
  DROP TABLE IF EXISTS _tc_claimed;
  CREATE TEMP TABLE _tc_claimed ON COMMIT DROP AS
  SELECT x.cur_tevo AS tevo_event_id FROM _tc_cand x WHERE x.cur_tevo IS NOT NULL
  UNION
  SELECT p.tevo_event_id FROM _tc_pick p
  UNION
  SELECT c.tevo_event_id FROM public.tickpick_catalog_event c
   WHERE c.tevo_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM _tc_drop d WHERE d.tp_event_id = c.tp_event_id);
  WITH per AS (
    SELECT f.tp_event_id,
           count(*) AS n_fit,
           min(f.tevo_event_id) AS one_fit,
           count(*) FILTER (WHERE f.same_minute) AS n_minute,
           min(f.tevo_event_id) FILTER (WHERE f.same_minute) AS one_minute
      FROM _tc_fit f
     WHERE NOT EXISTS (SELECT 1 FROM _tc_claimed c WHERE c.tevo_event_id = f.tevo_event_id)
     GROUP BY f.tp_event_id
  ),
  pick AS (
    SELECT p.tp_event_id,
           CASE WHEN p.n_fit = 1 THEN p.one_fit WHEN p.n_minute = 1 THEN p.one_minute END AS tevo_event_id,
           CASE WHEN p.n_fit = 1 THEN 'venue_day_name' WHEN p.n_minute = 1 THEN 'venue_time_name' END AS method
      FROM per p
  ),
  uniq AS (
    SELECT p.* FROM pick p
     WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.tp_event_id <> p.tp_event_id)
  )
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT u.tp_event_id, u.tevo_event_id, u.method FROM uniq u
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object(
    'picked', (SELECT count(*) FROM _tc_pick),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT method m, count(*) n FROM _tc_pick GROUP BY 1) s),
    'ambiguous', (SELECT count(DISTINCT f.tp_event_id) FROM _tc_fit f WHERE NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = f.tp_event_id)),
    'unmatched', (SELECT count(*) FROM _tc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = x.tp_event_id)),
    'no_venue', (SELECT count(*) FROM _tc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _tc_venue v WHERE v.tp_venue_id = x.tp_venue_id)));

  IF p_apply THEN
    UPDATE public.tickpick_catalog_event c
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = p.method, tevo_matched_at = now()
      FROM _tc_pick p WHERE p.tp_event_id = c.tp_event_id;
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.tp_event_id, 'match', 'tickpick_catalog_event', p.tp_event_id::text, p.tevo_event_id, p.method FROM _tc_pick p;

    WITH cnt AS (
      SELECT c.tp_venue_id, count(*) AS n
        FROM public.tickpick_catalog_event c JOIN public.events e ON e.id = c.tevo_event_id
        JOIN _tc_venue v ON v.tp_venue_id = c.tp_venue_id AND v.tevo_venue_id = e.venue_id
       GROUP BY c.tp_venue_id
    ),
    u AS (
      INSERT INTO public.tickpick_catalog_venue AS v (tp_venue_id, tevo_venue_id, method, events, derived_at)
      SELECT t.tp_venue_id, t.tevo_venue_id, t.method, coalesce(cnt.n, 0), now()
        FROM _tc_venue t LEFT JOIN cnt ON cnt.tp_venue_id = t.tp_venue_id
      ON CONFLICT (tp_venue_id) DO UPDATE
        SET tevo_venue_id = EXCLUDED.tevo_venue_id, method = EXCLUDED.method, events = EXCLUDED.events, derived_at = now()
        WHERE v.method IS DISTINCT FROM 'manual'
          AND (v.tevo_venue_id IS DISTINCT FROM EXCLUDED.tevo_venue_id OR v.method IS DISTINCT FROM EXCLUDED.method
               OR v.events IS DISTINCT FROM EXCLUDED.events)
      RETURNING v.tp_venue_id, v.tevo_venue_id, v.method, v.events)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'tickpick_catalog_venue', u.tp_venue_id::text, format('tevo_venue %s via %s (%s events)', u.tevo_venue_id, u.method, u.events) FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_written', v_n);

    -- 5. hub: the TickPick id on the hub rows of matched EVO events (fill-only; one TickPick id per EVO event)
    WITH tp AS (
      SELECT c.tevo_event_id, min(c.tp_event_id) AS tp_event_id
        FROM public.tickpick_catalog_event c
       WHERE c.tevo_event_id IS NOT NULL AND c.event_date >= current_date - 1
       GROUP BY c.tevo_event_id HAVING count(*) = 1
    ),
    u AS (
      UPDATE public.aq_event_map a SET tp_event_id = tp.tp_event_id
        FROM tp
       WHERE a.tevo_event_id = tp.tevo_event_id AND a.tp_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.tp_event_id = tp.tp_event_id AND o.tevo_event_id IS DISTINCT FROM tp.tevo_event_id)
       RETURNING a.aq_short_event_id, a.tevo_event_id, tp.tp_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'hub_tp', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_tp_filled', v_n);

    -- 6. orders: by id, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.tickpick_orders o
         SET tevo_event_id = c.tevo_event_id, matched_via = 'tp_catalog_id', match_confidence = 1.0, matched_at = now()
        FROM public.tickpick_catalog_event c
       WHERE o.tevo_event_id IS NULL AND o.event_date >= now() - interval '1 day' AND (o.raw->'event'->>'event_id') ~ '^\d+$'
         AND c.tp_event_id = (o.raw->'event'->>'event_id')::bigint AND c.tevo_event_id IS NOT NULL
       RETURNING o.tp_order_id, c.tp_event_id, c.tevo_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'order_tevo', 'tickpick_orders', u.tp_order_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_filled', v_n);
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, old_tevo, new_tevo, note)
    SELECT v_run, c.tp_event_id, 'order_disagree', 'tickpick_orders', o.tp_order_id, o.tevo_event_id, c.tevo_event_id, coalesce(o.matched_via, '?')
      FROM public.tickpick_orders o
      JOIN public.tickpick_catalog_event c ON (o.raw->'event'->>'event_id') ~ '^\d+$' AND c.tp_event_id = (o.raw->'event'->>'event_id')::bigint
     WHERE o.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id
       AND o.event_date >= now() - interval '1 day'
       AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_audit a
                        WHERE a.action = 'order_disagree' AND a.target_key = o.tp_order_id AND a.new_tevo = c.tevo_event_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_disagree_new', v_n);

    -- 7. the venue xref: aq_venue_map.tickpick_venue_id (UNIQUE), fill-only, once two matched events corroborate the pairing
    WITH u AS (
      UPDATE public.aq_venue_map m SET tickpick_venue_id = v.tp_venue_id
        FROM public.tickpick_catalog_venue v
       WHERE v.tevo_venue_id = m.tevo_venue_id AND m.tickpick_venue_id IS NULL AND v.tevo_venue_id IS NOT NULL
         AND (v.method = 'manual' OR coalesce(v.events, 0) >= 2)
         AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tickpick_venue_id = v.tp_venue_id)
         AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_venue w WHERE w.tevo_venue_id = v.tevo_venue_id AND w.tp_venue_id <> v.tp_venue_id)
       RETURNING m.venue_short_id, m.tevo_venue_id, v.tp_venue_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_map', 'aq_venue_map', u.venue_short_id, 'tickpick_venue ' || u.tp_venue_id || ' on tevo_venue ' || u.tevo_venue_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venue_map_filled', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

CREATE OR REPLACE FUNCTION public.vivid_catalog_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_out jsonb := '{}'::jsonb;
  v_n   int;
BEGIN
  -- one writer of vivid_catalog_event at a time: the minute tick (vivid_catalog_tick) skips its minute while this runs
  PERFORM pg_advisory_xact_lock(hashtext('vivid_catalog'));

  -- 0. candidates: upcoming, local day known, at venues in the US, Canada or Mexico (mig 20261117080000)
  DROP TABLE IF EXISTS _vc_cand;
  CREATE TEMP TABLE _vc_cand ON COMMIT DROP AS
  SELECT c.vivid_event_id, c.name, c.performers, c.vivid_venue_id, c.event_date, c.time_known,
         CASE WHEN c.time_known AND c.timezone IS NOT NULL AND c.timezone IN (SELECT name FROM pg_timezone_names)
              THEN c.event_local AT TIME ZONE c.timezone END AS event_utc,
         c.tevo_event_id AS cur_tevo, c.tevo_match_method AS cur_method
    FROM public.vivid_catalog_event c
   WHERE c.event_date BETWEEN current_date - 1 AND current_date + 400
     AND coalesce(c.venue_country, 'US') IN ('US', 'CA', 'MX');
  CREATE INDEX ON _vc_cand (vivid_event_id);
  v_out := v_out || jsonb_build_object('candidates', (SELECT count(*) FROM _vc_cand));

  -- 1. verify the matched
  DROP TABLE IF EXISTS _vc_drop;
  CREATE TEMP TABLE _vc_drop ON COMMIT DROP AS
  SELECT x.vivid_event_id, x.cur_tevo, x.cur_method,
         CASE WHEN e.id IS NULL THEN 'event_gone' WHEN e.state = 'ignored' THEN 'event_ignored' ELSE 'day_moved' END AS why
    FROM _vc_cand x LEFT JOIN public.events e ON e.id = x.cur_tevo
   WHERE x.cur_tevo IS NOT NULL
     AND (e.id IS NULL OR e.state = 'ignored' OR left(e.occurs_at_local, 10) IS DISTINCT FROM to_char(x.event_date, 'YYYY-MM-DD'));
  v_out := v_out || jsonb_build_object('dropped', (SELECT count(*) FROM _vc_drop));
  IF p_apply THEN
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.vivid_event_id, 'drop', 'vivid_catalog_event', d.vivid_event_id::text, d.cur_tevo, d.why || ' (' || coalesce(d.cur_method, '?') || ')' FROM _vc_drop d;
    UPDATE public.vivid_catalog_event c SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL
      FROM _vc_drop d WHERE d.vivid_event_id = c.vivid_event_id;
  END IF;
  UPDATE _vc_cand x SET cur_tevo = NULL, cur_method = NULL FROM _vc_drop d WHERE d.vivid_event_id = x.vivid_event_id;

  DROP TABLE IF EXISTS _vc_pick;
  CREATE TEMP TABLE _vc_pick (vivid_event_id bigint PRIMARY KEY, tevo_event_id bigint NOT NULL, method text NOT NULL) ON COMMIT DROP;

  -- 2. identity: the hub's vivid_event_id; our Vivid orders already mapped — same local day AND the name still fits
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT DISTINCT ON (x.vivid_event_id) x.vivid_event_id, a.tevo_event_id, 'hub_identity'
    FROM _vc_cand x
    JOIN public.aq_event_map a ON a.vivid_event_id = x.vivid_event_id AND a.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = a.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
   ORDER BY x.vivid_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT x.vivid_event_id, o.tevo, 'order_identity'
    FROM _vc_cand x
    JOIN (SELECT (o.raw->>'productionId')::bigint AS pid, o.tevo_event_id AS tevo
            FROM public.vivid_orders o
           WHERE o.tevo_event_id IS NOT NULL AND (o.raw->>'productionId') ~ '^\d+$'
           GROUP BY 1, 2) o ON o.pid = x.vivid_event_id
    JOIN public.events e ON e.id = o.tevo AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
     AND NOT EXISTS (SELECT 1 FROM public.vivid_orders o2
                      WHERE (o2.raw->>'productionId') ~ '^\d+$' AND (o2.raw->>'productionId')::bigint = x.vivid_event_id
                        AND o2.tevo_event_id IS NOT NULL AND o2.tevo_event_id <> o.tevo)
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object('identity', (SELECT count(*) FROM _vc_pick));

  -- 3. venues: manual -> name + state (mig 20261117080000) -> learned from matches
  DROP TABLE IF EXISTS _cat_tv;
  CREATE TEMP TABLE _cat_tv ON COMMIT DROP AS SELECT * FROM public.catalog_tevo_venues_by_name();
  CREATE INDEX ON _cat_tv (nm, st);
  DROP TABLE IF EXISTS _vc_venue;
  CREATE TEMP TABLE _vc_venue ON COMMIT DROP AS
  WITH known AS (
    SELECT v.vivid_venue_id, v.tevo_venue_id, 'manual' AS method, 1 AS pri
      FROM public.vivid_catalog_venue v WHERE v.method = 'manual' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT v.vivid_venue_id, t.tevo_venue_id, 'name_state', 2
      FROM public.vivid_catalog_venue v
      JOIN _cat_tv t ON t.nm = lower(trim(v.name)) AND t.st = upper(trim(v.state))
     WHERE coalesce(v.country, 'US') IN ('US', 'CA', 'MX') AND coalesce(v.state, '') <> ''
    UNION ALL
    SELECT s.vivid_venue_id, s.tv, 'matched_events', 3
      FROM (SELECT x.vivid_venue_id, e.venue_id AS tv, count(*) AS n,
                   row_number() OVER (PARTITION BY x.vivid_venue_id ORDER BY count(*) DESC, e.venue_id) AS rn
              FROM _vc_cand x
              LEFT JOIN _vc_pick p ON p.vivid_event_id = x.vivid_event_id
              JOIN public.events e ON e.id = coalesce(p.tevo_event_id, x.cur_tevo)
             WHERE x.vivid_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY x.vivid_venue_id, e.venue_id) s
     WHERE s.rn = 1
  )
  SELECT DISTINCT ON (k.vivid_venue_id) k.vivid_venue_id, k.tevo_venue_id, k.method FROM known k ORDER BY k.vivid_venue_id, k.pri;
  CREATE INDEX ON _vc_venue (vivid_venue_id);
  v_out := v_out || jsonb_build_object('venues_resolved', (SELECT count(*) FROM _vc_venue),
                                       'venues_by_method', (SELECT coalesce(jsonb_object_agg(method, n), '{}'::jsonb) FROM (SELECT method, count(*) n FROM _vc_venue GROUP BY 1) s));

  -- 4a. the EVO events the fits can see, once: upcoming, not ignored, indexed by venue and local day
  --     (mig 20261117090000: joining public.events by venue + left(occurs_at_local, 10) made the planner walk every
  --      event of the day and filter the venue afterwards — 377k rows thrown away for 757 pairs on a 60-day window)
  DROP TABLE IF EXISTS _cat_ev;
  CREATE TEMP TABLE _cat_ev ON COMMIT DROP AS
  SELECT e.id, e.venue_id, left(e.occurs_at_local, 10) AS day, e.name, e.primary_performer_name, e.occurs_at_local
    FROM public.events e
   WHERE e.occurs_at_local >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
     AND e.state IS DISTINCT FROM 'ignored' AND e.venue_id IS NOT NULL;
  CREATE INDEX ON _cat_ev (venue_id, day);
  ANALYZE _cat_ev;

  -- 4. venue + local day (+ name, + minute)
  DROP TABLE IF EXISTS _vc_fit;
  CREATE TEMP TABLE _vc_fit ON COMMIT DROP AS
  SELECT x.vivid_event_id, e.id AS tevo_event_id,
         (x.event_utc IS NOT NULL AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _vc_cand x
    JOIN _vc_venue v ON v.vivid_venue_id = x.vivid_venue_id
    JOIN _cat_ev e ON e.venue_id = v.tevo_venue_id AND e.day = to_char(x.event_date, 'YYYY-MM-DD')
   WHERE x.cur_tevo IS NULL
     AND NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = x.vivid_event_id)
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name);
  DROP TABLE IF EXISTS _vc_claimed;
  CREATE TEMP TABLE _vc_claimed ON COMMIT DROP AS
  SELECT x.cur_tevo AS tevo_event_id FROM _vc_cand x WHERE x.cur_tevo IS NOT NULL
  UNION SELECT p.tevo_event_id FROM _vc_pick p
  UNION SELECT c.tevo_event_id FROM public.vivid_catalog_event c
         WHERE c.tevo_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM _vc_drop d WHERE d.vivid_event_id = c.vivid_event_id);
  WITH per AS (
    SELECT f.vivid_event_id, count(*) AS n_fit, min(f.tevo_event_id) AS one_fit,
           count(*) FILTER (WHERE f.same_minute) AS n_minute, min(f.tevo_event_id) FILTER (WHERE f.same_minute) AS one_minute
      FROM _vc_fit f
     WHERE NOT EXISTS (SELECT 1 FROM _vc_claimed c WHERE c.tevo_event_id = f.tevo_event_id)
     GROUP BY f.vivid_event_id),
  pick AS (
    SELECT p.vivid_event_id,
           CASE WHEN p.n_fit = 1 THEN p.one_fit WHEN p.n_minute = 1 THEN p.one_minute END AS tevo_event_id,
           CASE WHEN p.n_fit = 1 THEN 'venue_day_name' WHEN p.n_minute = 1 THEN 'venue_time_name' END AS method
      FROM per p),
  uniq AS (
    SELECT p.* FROM pick p
     WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.vivid_event_id <> p.vivid_event_id))
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT u.vivid_event_id, u.tevo_event_id, u.method FROM uniq u
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object(
    'picked', (SELECT count(*) FROM _vc_pick),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT method m, count(*) n FROM _vc_pick GROUP BY 1) s),
    'ambiguous', (SELECT count(DISTINCT f.vivid_event_id) FROM _vc_fit f WHERE NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = f.vivid_event_id)),
    'unmatched', (SELECT count(*) FROM _vc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = x.vivid_event_id)),
    'no_venue', (SELECT count(*) FROM _vc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _vc_venue v WHERE v.vivid_venue_id = x.vivid_venue_id)));

  IF p_apply THEN
    UPDATE public.vivid_catalog_event c
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = p.method, tevo_matched_at = now()
      FROM _vc_pick p WHERE p.vivid_event_id = c.vivid_event_id;
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.vivid_event_id, 'match', 'vivid_catalog_event', p.vivid_event_id::text, p.tevo_event_id, p.method FROM _vc_pick p;

    WITH cnt AS (
      SELECT c.vivid_venue_id, count(*) AS n
        FROM public.vivid_catalog_event c JOIN public.events e ON e.id = c.tevo_event_id
        JOIN _vc_venue v ON v.vivid_venue_id = c.vivid_venue_id AND v.tevo_venue_id = e.venue_id
       GROUP BY c.vivid_venue_id),
    u AS (
      INSERT INTO public.vivid_catalog_venue AS v (vivid_venue_id, tevo_venue_id, method, events, derived_at)
      SELECT t.vivid_venue_id, t.tevo_venue_id, t.method, coalesce(cnt.n, 0), now()
        FROM _vc_venue t LEFT JOIN cnt ON cnt.vivid_venue_id = t.vivid_venue_id
      ON CONFLICT (vivid_venue_id) DO UPDATE
        SET tevo_venue_id = EXCLUDED.tevo_venue_id, method = EXCLUDED.method, events = EXCLUDED.events, derived_at = now()
        WHERE v.method IS DISTINCT FROM 'manual'
          AND (v.tevo_venue_id IS DISTINCT FROM EXCLUDED.tevo_venue_id OR v.method IS DISTINCT FROM EXCLUDED.method OR v.events IS DISTINCT FROM EXCLUDED.events)
      RETURNING v.vivid_venue_id, v.tevo_venue_id, v.method, v.events)
    INSERT INTO public.vivid_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'vivid_catalog_venue', u.vivid_venue_id::text, format('tevo_venue %s via %s (%s events)', u.tevo_venue_id, u.method, u.events) FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_written', v_n);

    -- 5. hub: vivid_event_id on the matched events' rows (fill-only; one Vivid id per EVO event)
    WITH vv AS (
      SELECT c.tevo_event_id, min(c.vivid_event_id) AS vivid_event_id
        FROM public.vivid_catalog_event c
       WHERE c.tevo_event_id IS NOT NULL AND c.event_date >= current_date - 1
       GROUP BY c.tevo_event_id HAVING count(*) = 1),
    u AS (
      UPDATE public.aq_event_map a SET vivid_event_id = vv.vivid_event_id
        FROM vv
       WHERE a.tevo_event_id = vv.tevo_event_id AND a.vivid_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.vivid_event_id = vv.vivid_event_id AND o.tevo_event_id IS DISTINCT FROM vv.tevo_event_id)
       RETURNING a.aq_short_event_id, a.tevo_event_id, vv.vivid_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.vivid_event_id, 'hub_vivid', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_vivid_filled', v_n);

    -- 6. orders: by productionId, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.vivid_orders o
         SET tevo_event_id = c.tevo_event_id
        FROM public.vivid_catalog_event c
       WHERE o.tevo_event_id IS NULL AND o.event_date >= now() - interval '1 day' AND (o.raw->>'productionId') ~ '^\d+$'
         AND c.vivid_event_id = (o.raw->>'productionId')::bigint AND c.tevo_event_id IS NOT NULL
       RETURNING o.vivid_order_id, c.vivid_event_id, c.tevo_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, u.vivid_event_id, 'order_tevo', 'vivid_orders', u.vivid_order_id, u.tevo_event_id, 'vivid_catalog_id' FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_filled', v_n);
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, old_tevo, new_tevo)
    SELECT v_run, c.vivid_event_id, 'order_disagree', 'vivid_orders', o.vivid_order_id, o.tevo_event_id, c.tevo_event_id
      FROM public.vivid_orders o
      JOIN public.vivid_catalog_event c ON (o.raw->>'productionId') ~ '^\d+$' AND c.vivid_event_id = (o.raw->>'productionId')::bigint
     WHERE o.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id
       AND o.event_date >= now() - interval '1 day'
       AND NOT EXISTS (SELECT 1 FROM public.vivid_catalog_audit a
                        WHERE a.action = 'order_disagree' AND a.target_key = o.vivid_order_id AND a.new_tevo = c.tevo_event_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_disagree_new', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

CREATE OR REPLACE FUNCTION public.vivid_catalog_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE s public.vivid_catalog_sync;
BEGIN
  -- mig 20261117090000: the hourly map holds this lock while it writes vivid_catalog_event; sit this minute out
  IF NOT pg_try_advisory_xact_lock(hashtext('vivid_catalog')) THEN
    RETURN jsonb_build_object('idle', true, 'reason', 'map_running');
  END IF;
  SELECT * INTO s FROM public.vivid_catalog_sync WHERE id = 1;
  -- a pass is open (next_page > 1) or due (none yet, or the last finished over 6 h ago)
  IF s.next_page > 1 OR s.pass_finished_at IS NULL OR s.pass_finished_at < now() - interval '6 hours' THEN
    RETURN public.vivid_catalog_pull(8);
  END IF;
  RETURN jsonb_build_object('idle', true, 'next_pass_after', s.pass_finished_at + interval '6 hours');
END $function$;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tickpick_catalog_hourly') THEN PERFORM cron.unschedule('tickpick_catalog_hourly'); END IF;
  PERFORM cron.schedule('tickpick_catalog_hourly', '41 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '300s'; SELECT public.tickpick_catalog_tick(); COMMIT;$j$);
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vivid_catalog_map_hourly') THEN PERFORM cron.unschedule('vivid_catalog_map_hourly'); END IF;
  PERFORM cron.schedule('vivid_catalog_map_hourly', '43 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '300s'; SELECT public.vivid_catalog_map(true); COMMIT;$j$);
END
$cron$;

COMMIT;
