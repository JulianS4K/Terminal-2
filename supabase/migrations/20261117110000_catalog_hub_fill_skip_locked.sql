-- Migration 20261117110000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tickpick_catalog_map() fn (hub + venue fills skip locked rows),vivid_catalog_map() fn (hub fill skips locked rows),mlb_ticket_map() fn (stadium title exclusion),mlb_ticket_event(one package row unmapped — DML),mlb_map_audit(DML) · reads:aq_event_map,aq_venue_map · pre:20261117100000
--
-- MAPPING PROGRAM — THE CATALOGUE MAPPERS NEVER WAIT FOR THE HUB.
--
-- First full hour after mig 20261117090000 (2026-11-17 18:41Z / 18:43Z): both catalogue mappers matched inside the
-- hour and then sat on one UPDATE of aq_event_map until the 300 s ceiling — "while updating tuple in relation
-- aq_event_map". The hub is inside long cron transactions around the clock (sg_classify_events_5min 272 s avg /
-- 900 s max every 5 min, retention_tick 654 s; PROJECT_BIBLE §0), so a fill that touches thousands of hub rows will
-- always meet a row one of them holds, and a row lock wait is bounded only by that transaction. The TickPick hub
-- fill that ran by hand at 18:11Z (378 rows) simply met none. Now the hub fill (both mappers) and TickPick's
-- aq_venue_map fill select their target rows FOR UPDATE SKIP LOCKED: a row another transaction holds is left for
-- the next hour instead of being waited for, and the matches of the hour are committed. Bodies otherwise those of
-- mig 20261117090000.
--
-- And the stadium-event rule of mig 20261117100000 matched "Fall Out Boy Cadillac Club Hospitality Package" to the
-- Fall Out Boy concert at Citi Field — the right show, but a hospitality product, not the concert. Titles naming a
-- package, hospitality, suite, parking, pre/post-game, pickup or membership are no longer candidates; the one such
-- match is unmapped here (fill-only rule, so its hub link goes on the next pass). Body otherwise mig 20261117100000's.
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
    tgt AS (   -- mig 20261117110000: a hub row another transaction holds is skipped, not waited for
      SELECT a.aq_short_event_id, tp.tp_event_id, tp.tevo_event_id
        FROM public.aq_event_map a JOIN tp ON tp.tevo_event_id = a.tevo_event_id
       WHERE a.tp_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.tp_event_id = tp.tp_event_id AND o.tevo_event_id IS DISTINCT FROM tp.tevo_event_id)
       FOR UPDATE OF a SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_event_map a SET tp_event_id = t.tp_event_id
        FROM tgt t
       WHERE a.aq_short_event_id = t.aq_short_event_id
       RETURNING a.aq_short_event_id, a.tevo_event_id, t.tp_event_id)
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
    WITH tgt AS (   -- mig 20261117110000: skip locked rows here too
      SELECT m.venue_short_id, m.tevo_venue_id, v.tp_venue_id
        FROM public.aq_venue_map m JOIN public.tickpick_catalog_venue v ON v.tevo_venue_id = m.tevo_venue_id
       WHERE m.tickpick_venue_id IS NULL AND v.tevo_venue_id IS NOT NULL
         AND (v.method = 'manual' OR coalesce(v.events, 0) >= 2)
         AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tickpick_venue_id = v.tp_venue_id)
         AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_venue w WHERE w.tevo_venue_id = v.tevo_venue_id AND w.tp_venue_id <> v.tp_venue_id)
       FOR UPDATE OF m SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_venue_map m SET tickpick_venue_id = t.tp_venue_id
        FROM tgt t WHERE m.venue_short_id = t.venue_short_id
       RETURNING m.venue_short_id, m.tevo_venue_id, t.tp_venue_id)
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
    tgt AS (   -- mig 20261117110000: a hub row another transaction holds is skipped, not waited for
      SELECT a.aq_short_event_id, vv.vivid_event_id, vv.tevo_event_id
        FROM public.aq_event_map a JOIN vv ON vv.tevo_event_id = a.tevo_event_id
       WHERE a.vivid_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.vivid_event_id = vv.vivid_event_id AND o.tevo_event_id IS DISTINCT FROM vv.tevo_event_id)
       FOR UPDATE OF a SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_event_map a SET vivid_event_id = t.vivid_event_id
        FROM tgt t
       WHERE a.aq_short_event_id = t.aq_short_event_id
       RETURNING a.aq_short_event_id, a.tevo_event_id, t.vivid_event_id)
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

CREATE OR REPLACE FUNCTION public.mlb_ticket_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run  uuid := gen_random_uuid();
  v_out  jsonb := '{}'::jsonb;
  v_by   jsonb;
  v_n    integer;
  v_hub_rows integer := 0;
  r      record;
  v_aq   text;
BEGIN
  -- 0. clubs -> TEvo performers: team_xref (MLB), else entity_performer_map by a name it carries exactly once
  DROP TABLE IF EXISTS _mm_team;
  CREATE TEMP TABLE _mm_team ON COMMIT DROP AS
  SELECT t.team_id,
         coalesce(t.tevo_performer_id,
                  (SELECT x.tevo_performer_id FROM public.team_xref x
                    WHERE t.sport_id = 1 AND x.espn_league = 'MLB' AND lower(x.tevo_name) = lower(t.full_name) LIMIT 1),
                  (SELECT min(e.tevo_performer_id) FROM public.entity_performer_map e
                    WHERE lower(e.tevo_performer_name) = lower(t.full_name) HAVING count(*) = 1)) AS pid
    FROM public.mlb_ticket_team t;
  IF p_apply THEN
    UPDATE public.mlb_ticket_team t SET tevo_performer_id = m.pid FROM _mm_team m
     WHERE m.team_id = t.team_id AND t.tevo_performer_id IS NULL AND m.pid IS NOT NULL;
  END IF;

  -- 1. verify every EVO match: still that game? (mig 20261117100000: a removed game is left as it is — its hub
  --    link goes in 1b; a doubleheader twin — a timed EVO listing on the OTHER game's minute that day — is dropped,
  --    so step 2 can hand it to the game it is, by MLB's minute, on the next pass)
  DROP TABLE IF EXISTS _mm_drop;
  CREATE TEMP TABLE _mm_drop ON COMMIT DROP AS
  SELECT g.schedule_id, g.tevo_event_id,
         CASE WHEN e.id IS NULL THEN 'event_gone'
              WHEN coalesce(e.state, 'shown') = 'ignored' THEN 'event_ignored'
              WHEN left(e.occurs_at_local, 10) <> g.game_date::text THEN 'date_moved'
              WHEN coalesce(dh.twin, false) THEN 'doubleheader_twin'
              ELSE 'clubs_differ' END AS reason
    FROM public.mlb_ticket_game g
    LEFT JOIN public.events e ON e.id = g.tevo_event_id
    LEFT JOIN _mm_team th ON th.team_id = g.home_team_id
    LEFT JOIN _mm_team ta ON ta.team_id = g.away_team_id
    LEFT JOIN LATERAL (
      SELECT true AS twin
        FROM public.mlb_ticket_game s
       WHERE e.id IS NOT NULL AND NOT coalesce(g.is_tbd, false) AND g.game_time_utc IS NOT NULL AND e.occurs_at_local !~ 'T00:00(:00)?'
         AND s.game_date = g.game_date AND s.home_team_id = g.home_team_id AND s.away_team_id = g.away_team_id
         AND s.schedule_id <> g.schedule_id AND s.removed_at IS NULL AND NOT coalesce(s.is_tbd, false) AND s.game_time_utc IS NOT NULL
         AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - s.game_time_utc)) <= 60
         AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - g.game_time_utc)) > 60
       LIMIT 1) dh ON true
   WHERE g.tevo_event_id IS NOT NULL AND g.game_date >= current_date - 1 AND g.removed_at IS NULL
     AND (coalesce(dh.twin, false)
          OR NOT (e.id IS NOT NULL AND coalesce(e.state, 'shown') <> 'ignored'
                  AND public.mlb_ticket_event_fits(e.name, e.occurs_at_local, e.performer_ids, g.game_date,
                                                   g.away_name, g.home_name, ta.pid, th.pid)));
  IF p_apply THEN
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.schedule_id, 'drop', 'mlb_ticket_game', d.schedule_id::text, d.tevo_event_id, d.reason FROM _mm_drop d;
    DELETE FROM public.mlb_hub_link l USING _mm_drop d WHERE l.schedule_id = d.schedule_id;
    UPDATE public.mlb_ticket_game g
       SET tevo_event_id = NULL, tevo_matched_at = NULL, tevo_match_method = NULL, changed_at = now()
      FROM _mm_drop d WHERE d.schedule_id = g.schedule_id;
  END IF;
  SELECT count(*) INTO v_n FROM _mm_drop;
  v_out := v_out || jsonb_build_object('dropped', v_n);

  -- 1b. a removed game or stadium event (mlb_ticket_tick: no longer on the club's schedule) keeps its EVO id — the
  --     tick restores it when the row comes back — but leaves the hub (mig 20261117100000)
  DROP TABLE IF EXISTS _mm_removed;
  CREATE TEMP TABLE _mm_removed ON COMMIT DROP AS
  SELECT l.entity, l.schedule_id, l.aq_short_event_id, l.tevo_event_id
    FROM public.mlb_hub_link l
   WHERE (l.entity = 'game'  AND EXISTS (SELECT 1 FROM public.mlb_ticket_game  g WHERE g.schedule_id = l.schedule_id AND g.removed_at IS NOT NULL))
      OR (l.entity = 'event' AND EXISTS (SELECT 1 FROM public.mlb_ticket_event v WHERE v.schedule_id = l.schedule_id AND v.removed_at IS NOT NULL));
  IF p_apply THEN
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, rm.schedule_id, 'hub_unlink', 'mlb_hub_link', rm.aq_short_event_id, rm.tevo_event_id, rm.entity || ' removed' FROM _mm_removed rm;
    DELETE FROM public.mlb_hub_link l USING _mm_removed rm WHERE l.entity = rm.entity AND l.schedule_id = rm.schedule_id;
  END IF;
  v_out := v_out || jsonb_build_object('removed_unlinked', (SELECT count(*) FROM _mm_removed));

  -- 1c. MLB's start against the EVO listing's: a timed listing more than ten minutes off is flagged once
  --     (mlb_map_audit 'time_differs'), never dropped — the clubs are named and the day agrees, so it is the game,
  --     listed at a different hour. EVO's T12:00 / T23:59 / T03:30 (and T00:00) stand for "time to be announced":
  --     on 2026-11-17 they made 758 of the 808 games the feed view (v_mlb_schedule_feed.tevo_time_check) called
  --     'differs', so they are read as unknown here (mig 20261117100000)
  DROP TABLE IF EXISTS _mm_tdiff;
  CREATE TEMP TABLE _mm_tdiff ON COMMIT DROP AS
  SELECT g.schedule_id, g.tevo_event_id,
         format('evo %s vs mlb %s (%s min)', left(e.occurs_at_local, 16), to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI'),
                round(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - g.game_time_utc) / 60)) AS note
    FROM public.mlb_ticket_game g
    JOIN public.events e ON e.id = g.tevo_event_id
   WHERE g.game_date >= current_date AND g.removed_at IS NULL AND NOT coalesce(g.is_tbd, false) AND g.game_time_utc IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM _mm_drop d WHERE d.schedule_id = g.schedule_id)
     AND e.occurs_at_local !~ 'T(00:00|12:00|23:59|03:30)'
     AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - g.game_time_utc)) > 600;
  IF p_apply THEN
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, t.schedule_id, 'time_differs', 'mlb_ticket_game', t.schedule_id::text, t.tevo_event_id, t.note FROM _mm_tdiff t
     WHERE NOT EXISTS (SELECT 1 FROM public.mlb_map_audit a
                        WHERE a.action = 'time_differs' AND a.schedule_id = t.schedule_id AND a.old_tevo = t.tevo_event_id AND a.note = t.note);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('time_differs_new', v_n);
  END IF;
  v_out := v_out || jsonb_build_object('time_differs', (SELECT count(*) FROM _mm_tdiff));

  -- 2. match the unmatched: both clubs on the game's local day, one game per EVO event
  DROP TABLE IF EXISTS _mm_cand;
  CREATE TEMP TABLE _mm_cand ON COMMIT DROP AS
  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.is_tbd, g.game_time_utc, g.away_name, g.home_name,
           ta.pid AS away_pid, th.pid AS home_pid
      FROM public.mlb_ticket_game g
      LEFT JOIN _mm_team th ON th.team_id = g.home_team_id
      LEFT JOIN _mm_team ta ON ta.team_id = g.away_team_id
     WHERE g.tevo_event_id IS NULL AND g.game_date >= current_date - 1 AND g.removed_at IS NULL
       AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM _mm_drop d WHERE d.schedule_id = g.schedule_id))   -- a dropped match is not re-matched in the same pass
  SELECT t.schedule_id, t.is_tbd, t.game_time_utc, e.id AS tevo_event_id,
         (e.occurs_at_local ~ 'T00:00(:00)?') AS placeholder,
         public.tevo_event_utc(e.occurs_at_local, e.venue_id) AS tevo_utc
    FROM todo t
    JOIN public.events e
      ON left(e.occurs_at_local, 10) = t.game_date::text
     AND coalesce(e.state, 'shown') <> 'ignored'
     AND lower(e.name) !~ '(parking|tailgate|package)'
     AND public.mlb_ticket_event_fits(e.name, e.occurs_at_local, e.performer_ids, t.game_date,
                                      t.away_name, t.home_name, t.away_pid, t.home_pid)
   WHERE NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o WHERE o.tevo_event_id = e.id
                        AND NOT EXISTS (SELECT 1 FROM _mm_drop d WHERE d.schedule_id = o.schedule_id));

  DROP TABLE IF EXISTS _mm_pick;
  CREATE TEMP TABLE _mm_pick ON COMMIT DROP AS
  WITH c AS (
    SELECT c.*,
           count(*) OVER (PARTITION BY c.schedule_id) AS n_all,
           count(*) FILTER (WHERE NOT c.placeholder) OVER (PARTITION BY c.schedule_id) AS n_timed,
           (NOT c.is_tbd AND NOT c.placeholder AND c.tevo_utc IS NOT NULL AND c.game_time_utc IS NOT NULL
            AND abs(extract(epoch FROM c.tevo_utc - c.game_time_utc)) <= 60) AS same_minute
      FROM _mm_cand c),
  p AS (
    SELECT schedule_id, min(tevo_event_id) AS tevo_event_id, 'teams_date'::text AS method
      FROM c WHERE n_all = 1 GROUP BY 1
    UNION ALL
    SELECT schedule_id, min(tevo_event_id), 'teams_date_timed'
      FROM c WHERE n_all > 1 AND n_timed = 1 AND NOT placeholder GROUP BY 1
    UNION ALL
    SELECT schedule_id, min(tevo_event_id), 'teams_date_time'
      FROM c WHERE n_timed > 1 AND same_minute GROUP BY 1 HAVING count(*) = 1)
  SELECT p.* FROM p
   WHERE NOT EXISTS (SELECT 1 FROM p o WHERE o.tevo_event_id = p.tevo_event_id AND o.schedule_id <> p.schedule_id);  -- two games, one listing: neither

  IF p_apply THEN
    UPDATE public.mlb_ticket_game g
       SET tevo_event_id = p.tevo_event_id, tevo_matched_at = now(), tevo_match_method = p.method, changed_at = now()
      FROM _mm_pick p
     WHERE g.schedule_id = p.schedule_id AND g.tevo_event_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o WHERE o.tevo_event_id = p.tevo_event_id AND o.schedule_id <> g.schedule_id);
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.schedule_id, 'match', 'mlb_ticket_game', p.schedule_id::text, p.tevo_event_id, p.method FROM _mm_pick p;
  END IF;

  -- the game -> EVO event picture as this pass leaves it (the same in a dry run); the stadium events join it in step 7
  DROP TABLE IF EXISTS _mm_eff;
  CREATE TEMP TABLE _mm_eff ON COMMIT DROP AS
  SELECT 'game'::text AS entity, g.schedule_id,
         CASE WHEN d.schedule_id IS NOT NULL THEN NULL ELSE coalesce(p.tevo_event_id, g.tevo_event_id) END AS tevo_event_id
    FROM public.mlb_ticket_game g
    LEFT JOIN _mm_drop d ON d.schedule_id = g.schedule_id
    LEFT JOIN _mm_pick p ON p.schedule_id = g.schedule_id
   WHERE g.game_date >= current_date - 1 AND g.removed_at IS NULL;

  SELECT coalesce(jsonb_object_agg(x.method, x.n), '{}'::jsonb) INTO v_by FROM (SELECT method, count(*) AS n FROM _mm_pick GROUP BY 1) x;
  SELECT count(*) INTO v_n FROM _mm_pick;
  v_out := v_out || jsonb_build_object('matched', v_n, 'matched_by', v_by,
             'ambiguous', (SELECT count(DISTINCT c.schedule_id) FROM _mm_cand c WHERE NOT EXISTS (SELECT 1 FROM _mm_pick p WHERE p.schedule_id = c.schedule_id)),
             'unmatched', (SELECT count(*) FROM _mm_eff x WHERE x.entity = 'game' AND x.tevo_event_id IS NULL));

  -- 3. the seller's own event id from the direct ticket URL
  IF p_apply THEN
    WITH p AS (
      SELECT g.schedule_id,
             CASE WHEN g.ticket_url ~  '^https://www\.ticketmaster\.com/event/' THEN 'ticketmaster'
                  WHEN g.ticket_url ~* 'glitnir'                                  THEN 'glitnir'
                  WHEN g.ticket_url ~* '[?&](pid|eventid)=[0-9]+'                 THEN 'provenue' END AS seller,
             coalesce(substring(g.ticket_url from '^https://www\.ticketmaster\.com/event/([0-9A-Za-z]+)'),
                      substring(g.ticket_url from '(?i)[?&]pid=([0-9]+)'),
                      substring(g.ticket_url from '(?i)[?&]eventid=([0-9]+)'),
                      substring(g.ticket_url from '(?i)[?&]event_id=([0-9]+)')) AS eid
        FROM public.mlb_ticket_game g
       WHERE g.ticket_url IS NOT NULL OR g.primary_event_id IS NOT NULL)
    UPDATE public.mlb_ticket_game g
       SET primary_seller = p.seller, primary_event_id = CASE WHEN p.seller IS NULL THEN NULL ELSE p.eid END
      FROM p
     WHERE p.schedule_id = g.schedule_id
       AND (g.primary_seller, g.primary_event_id) IS DISTINCT FROM (p.seller, CASE WHEN p.seller IS NULL THEN NULL ELSE p.eid END);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('primary_ids_set', v_n);
  END IF;

  -- 4. parks: the EVO venue the matched games point at
  IF p_apply THEN
    INSERT INTO public.mlb_venue_xref (mlb_venue_id, venue_name, venue_city, tevo_venue_id, tevo_venue_name, games, method, derived_at)
    SELECT DISTINCT ON (s.venue_id) s.venue_id, s.venue_name, s.venue_city, s.tv, s.tvn, s.n, 'matched_games', now()
      FROM (SELECT g.venue_id, max(g.venue_name) AS venue_name, max(g.venue_city) AS venue_city,
                   e.venue_id AS tv, max(e.venue_name) AS tvn, count(*) AS n
              FROM public.mlb_ticket_game g JOIN public.events e ON e.id = g.tevo_event_id
             WHERE g.venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY g.venue_id, e.venue_id) s
     ORDER BY s.venue_id, s.n DESC, s.tv
    ON CONFLICT (mlb_venue_id) DO UPDATE
       SET venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city, tevo_venue_id = EXCLUDED.tevo_venue_id,
           tevo_venue_name = EXCLUDED.tevo_venue_name, games = EXCLUDED.games, derived_at = now()
     WHERE public.mlb_venue_xref.method = 'matched_games';
    UPDATE public.mlb_ticket_game g SET tevo_venue_id = x.tevo_venue_id
      FROM public.mlb_venue_xref x
     WHERE x.mlb_venue_id = g.venue_id AND g.tevo_venue_id IS DISTINCT FROM x.tevo_venue_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_known', (SELECT count(*) FROM public.mlb_venue_xref WHERE tevo_venue_id IS NOT NULL), 'games_venue_set', v_n);
  END IF;

  -- 7. stadium events (mlb_ticket_event, mig 20261117060000: the concerts and other non-game dates the clubs sell).
  --    mlb_ticket_match_events() pairs them by venue name + day; this adds the park's known EVO venue (mlb_venue_xref,
  --    step 4), a title that shares a word with the EVO listing, a day with no game at the park, one candidate —
  --    fill-only, so the tick's own match stands where it has one (mig 20261117100000)
  DROP TABLE IF EXISTS _mm_evpick;
  CREATE TEMP TABLE _mm_evpick ON COMMIT DROP AS
  WITH todo AS (
    SELECT v.schedule_id, v.event_date, v.title, x.tevo_venue_id
      FROM public.mlb_ticket_event v
      JOIN public.mlb_venue_xref x ON x.mlb_venue_id = v.venue_id AND x.tevo_venue_id IS NOT NULL
     WHERE v.tevo_event_id IS NULL AND v.removed_at IS NULL AND v.event_date >= current_date AND NOT coalesce(v.is_tbd, false)
       AND v.title !~* '(package|hospitality|suites?\M|parking|pre-?game|post-?game|pickup|membership)'   -- mig 20261117110000: a product sold around the show is not the show
       AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game g WHERE g.venue_id = v.venue_id AND g.game_date = v.event_date AND g.removed_at IS NULL)),
  cand AS (
    SELECT t.schedule_id, e.id, count(*) OVER (PARTITION BY t.schedule_id) AS n
      FROM todo t
      JOIN public.events e ON left(e.occurs_at_local, 10) = t.event_date::text AND e.venue_id = t.tevo_venue_id
                          AND coalesce(e.state, 'shown') <> 'ignored' AND lower(e.name) !~ '(parking|tailgate|package)'
                          AND public.mlb_stadium_title_fits(t.title, e.name))
  SELECT c.schedule_id, c.id AS tevo_event_id
    FROM cand c
   WHERE c.n = 1
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game  g WHERE g.tevo_event_id = c.id)
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_event o WHERE o.tevo_event_id = c.id)
     AND NOT EXISTS (SELECT 1 FROM cand o WHERE o.id = c.id AND o.schedule_id <> c.schedule_id);
  IF p_apply THEN
    UPDATE public.mlb_ticket_event v
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = 'venue_xref_title', tevo_matched_at = now(), changed_at = now()
      FROM _mm_evpick p WHERE p.schedule_id = v.schedule_id AND v.tevo_event_id IS NULL;
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.schedule_id, 'event_match', 'mlb_ticket_event', p.schedule_id::text, p.tevo_event_id, 'venue_xref_title' FROM _mm_evpick p;
  END IF;
  INSERT INTO _mm_eff (entity, schedule_id, tevo_event_id)
  SELECT 'event', v.schedule_id, coalesce(p.tevo_event_id, v.tevo_event_id)
    FROM public.mlb_ticket_event v
    LEFT JOIN _mm_evpick p ON p.schedule_id = v.schedule_id
   WHERE v.event_date >= current_date - 1 AND v.removed_at IS NULL;
  v_out := v_out || jsonb_build_object('events_matched', (SELECT count(*) FROM _mm_evpick),
             'events_unmatched', (SELECT count(*) FROM _mm_eff x WHERE x.entity = 'event' AND x.tevo_event_id IS NULL));

  -- 5. SeatGeek's EVO link for a game the schedule proves
  DROP TABLE IF EXISTS _mm_sg;
  CREATE TEMP TABLE _mm_sg ON COMMIT DROP AS
  SELECT c.sg_event_id, g.schedule_id, c.tevo_event_id AS old_tevo, x.tevo_event_id AS new_tevo,
         CASE WHEN c.tevo_event_id IS NULL THEN 'sg_fill' ELSE 'sg_repoint' END AS action,
         c.match_method AS old_method
    FROM public.mlb_ticket_game g
    JOIN _mm_eff x ON x.entity = 'game' AND x.schedule_id = g.schedule_id AND x.tevo_event_id IS NOT NULL
    JOIN public.sg_events_canonical c ON c.sg_event_id = g.sg_event_id
    LEFT JOIN public.events e2 ON e2.id = c.tevo_event_id
    LEFT JOIN _mm_team th ON th.team_id = g.home_team_id
    LEFT JOIN _mm_team ta ON ta.team_id = g.away_team_id
   WHERE c.tevo_event_id IS DISTINCT FROM x.tevo_event_id
     AND NOT (e2.id IS NOT NULL AND coalesce(e2.state, 'shown') <> 'ignored'
              AND public.mlb_ticket_event_fits(e2.name, e2.occurs_at_local, e2.performer_ids, g.game_date,
                                               g.away_name, g.home_name, ta.pid, th.pid));
  IF p_apply THEN
    UPDATE public.sg_events_canonical c
       SET tevo_event_id = s.new_tevo, match_method = 'mlb_schedule', match_confidence = 1.0, matched_at = now(), updated_at = now()
      FROM _mm_sg s WHERE c.sg_event_id = s.sg_event_id;
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, new_tevo, old_sg, new_sg, note)
    SELECT v_run, s.schedule_id, s.action, 'sg_events_canonical', s.sg_event_id::text, s.old_tevo, s.new_tevo, s.sg_event_id, s.sg_event_id, s.old_method FROM _mm_sg s;
  END IF;
  SELECT coalesce(jsonb_object_agg(x.action, x.n), '{}'::jsonb) INTO v_by FROM (SELECT action, count(*) AS n FROM _mm_sg GROUP BY 1) x;
  v_out := v_out || jsonb_build_object('seatgeek', v_by);

  -- 6. the hub knows the game (and, mig 20261117100000, the stadium event)
  DROP TABLE IF EXISTS _mm_hubrow;
  CREATE TEMP TABLE _mm_hubrow ON COMMIT DROP AS      -- one hub row per EVO event of a mapped game: one scan of the hub, hash-joined
  SELECT DISTINCT ON (a.tevo_event_id) a.tevo_event_id, a.aq_short_event_id
    FROM public.aq_event_map a
    JOIN (SELECT DISTINCT x.tevo_event_id FROM _mm_eff x WHERE x.tevo_event_id IS NOT NULL) x ON x.tevo_event_id = a.tevo_event_id
   ORDER BY a.tevo_event_id,
            EXISTS (SELECT 1 FROM public.mlb_hub_link l WHERE l.aq_short_event_id = a.aq_short_event_id) DESC,   -- the row already tied to a game
            (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST, a.aq_short_event_id;
  DROP TABLE IF EXISTS _mm_hub;
  CREATE TEMP TABLE _mm_hub ON COMMIT DROP AS
  SELECT 'game'::text AS entity, g.schedule_id, x.tevo_event_id, g.sg_event_id, g.away_name || ' at ' || g.home_name AS nm, g.venue_name,
         coalesce(g.game_time_local, g.game_date::timestamp) AS starts, e.venue_id AS tevo_venue_id,
         h.aq_short_event_id AS aq, false AS created
    FROM public.mlb_ticket_game g
    JOIN _mm_eff x ON x.entity = 'game' AND x.schedule_id = g.schedule_id AND x.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = x.tevo_event_id
    LEFT JOIN _mm_hubrow h ON h.tevo_event_id = x.tevo_event_id
  UNION ALL
  SELECT 'event', v.schedule_id, x.tevo_event_id, NULL::bigint, v.title, v.venue_name,
         coalesce(v.event_time_local, v.event_date::timestamp), e.venue_id, h.aq_short_event_id, false
    FROM public.mlb_ticket_event v
    JOIN _mm_eff x ON x.entity = 'event' AND x.schedule_id = v.schedule_id AND x.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = x.tevo_event_id
    LEFT JOIN _mm_hubrow h ON h.tevo_event_id = x.tevo_event_id;
  v_out := v_out || jsonb_build_object('hub_rows_missing', (SELECT count(*) FROM _mm_hub WHERE aq IS NULL));
  IF p_apply THEN
    FOR r IN SELECT * FROM _mm_hub h WHERE h.aq IS NULL ORDER BY h.entity, h.schedule_id LOOP
      v_aq := public.create_system_aq_event('mlb', r.nm, r.venue_name, r.starts::timestamptz, r.schedule_id);
      UPDATE public.aq_event_map
         SET tevo_event_id = r.tevo_event_id, tevo_venue_id = coalesce(tevo_venue_id, r.tevo_venue_id),
             primary_source = coalesce(primary_source, 'tevo')
       WHERE aq_short_event_id = v_aq AND tevo_event_id IS NULL;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN
        UPDATE _mm_hub SET aq = v_aq, created = true WHERE entity = r.entity AND schedule_id = r.schedule_id;
        v_hub_rows := v_hub_rows + 1;
      END IF;   -- else: the SYS id already belongs to another EVO event (same name, park and start) -- the game stays without a hub row
    END LOOP;
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, note)
    SELECT v_run, h.schedule_id, 'hub_row', 'aq_event_map', h.aq, h.tevo_event_id, h.entity FROM _mm_hub h WHERE h.created;

    -- a link whose hub row no longer is the game's EVO event (the game was re-matched, or the row changed) goes
    WITH u AS (
      DELETE FROM public.mlb_hub_link l
       USING _mm_eff x
       WHERE x.entity = l.entity AND x.schedule_id = l.schedule_id
         AND x.tevo_event_id IS DISTINCT FROM (SELECT a.tevo_event_id FROM public.aq_event_map a WHERE a.aq_short_event_id = l.aq_short_event_id)
       RETURNING l.aq_short_event_id, l.schedule_id, l.tevo_event_id, l.entity)
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, u.schedule_id, 'hub_unlink', 'mlb_hub_link', u.aq_short_event_id, u.tevo_event_id, u.entity || ' re-matched' FROM u;

    -- every mapped game tied to its hub row, one game per row
    WITH u AS (
      INSERT INTO public.mlb_hub_link (entity, schedule_id, aq_short_event_id, tevo_event_id)
      SELECT h.entity, h.schedule_id, h.aq, h.tevo_event_id FROM _mm_hub h
       WHERE h.aq IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM public.mlb_hub_link l WHERE (l.entity = h.entity AND l.schedule_id = h.schedule_id) OR l.aq_short_event_id = h.aq)
      RETURNING aq_short_event_id, schedule_id, tevo_event_id)
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo)
    SELECT v_run, u.schedule_id, 'hub_link', 'mlb_hub_link', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_rows_created', v_hub_rows, 'hub_linked', v_n);

    WITH u AS (
      UPDATE public.aq_event_map a SET sg_event_id = h.sg_event_id
        FROM _mm_hub h
       WHERE a.aq_short_event_id = h.aq AND a.sg_event_id IS NULL AND h.sg_event_id IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.sg_event_id = h.sg_event_id AND o.tevo_event_id IS DISTINCT FROM h.tevo_event_id)
       RETURNING a.aq_short_event_id, h.schedule_id, h.tevo_event_id, h.sg_event_id)
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, new_sg)
    SELECT v_run, u.schedule_id, 'hub_sg', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id, u.sg_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_sg_filled', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

-- the one package row the first pass mapped (2026-11-17 18:26Z); guarded so a database without the schedule tables loads the file
DO $fix$
BEGIN
  IF to_regclass('public.mlb_ticket_event') IS NULL THEN RETURN; END IF;
  WITH sel AS (
    SELECT v.schedule_id, v.tevo_event_id
      FROM public.mlb_ticket_event v
     WHERE v.tevo_match_method = 'venue_xref_title'
       AND v.title ~* '(package|hospitality|suites?\M|parking|pre-?game|post-?game|pickup|membership)'),
  upd AS (
    UPDATE public.mlb_ticket_event v
       SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL, changed_at = now()
      FROM sel WHERE sel.schedule_id = v.schedule_id
    RETURNING v.schedule_id)
  INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
  SELECT gen_random_uuid(), s.schedule_id, 'event_drop', 'mlb_ticket_event', s.schedule_id::text, s.tevo_event_id, 'package title (mig 20261117110000)'
    FROM sel s JOIN upd u ON u.schedule_id = s.schedule_id;
END
$fix$;

COMMIT;

-- VERIFY:
--   cron.job_run_details for tickpick_catalog_hourly (:41) and vivid_catalog_map_hourly (:43) succeed within 300 s
--   SELECT action, count(*) FROM vivid_catalog_audit GROUP BY 1;   SELECT * FROM v_event_catalogues;
