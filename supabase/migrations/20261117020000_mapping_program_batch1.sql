-- Migration 20261117020000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:venue_xref_derive_from_events() fn (one target per marketplace venue id), event_mapper_resolve_staged() fn (hub lookups as indexed UNIONs), sg_canonical_verify_day() fn (new), sg_events_canonical.tevo_event_id (verifier repoints), aq_event_map.sg_event_id (verifier hub fix), sg_night_correction_log (verifier rows), v_mapping_pipeline_health (stalled needs a backlog), cron:sg_canonical_verify_hourly · reads:events, sg_events_canonical, aq_event_map, cross_source_venue_map, aq_venue_map, tickets_dev_source_id · pre:20261117000000
--
-- MAPPING PROGRAM, BATCH 1 (operator 2026-11-17: "absorb all mapping duties from all agents and work on them";
-- KANBAN "Mapping program" MAP-2, MAP-3, MAP-4, MAP-6). Four independent fixes, each the whole function or view
-- (MIGRATION_CONVENTIONS §6a). Nothing upstream is called (RULE 2).
--
-- MAP-3 · venue_xref_derive_from_events() — cron 584 venue_xref_derive_daily has failed 7 of 7 days:
--   "duplicate key value violates unique constraint aq_venue_map_sg_venue_id_key (sg_venue_id)=(1333)".
--   cross_source_venue_map carries 18 SeatGeek venue ids on more than one TEvo venue; the fill UPDATE on
--   aq_venue_map joined through tevo_venue_id and so tried to give one SeatGeek id to two rows in the same
--   statement — its NOT EXISTS guard only sees rows committed before the statement. Now one target row per
--   marketplace id (DISTINCT ON), for SeatGeek and TickPick alike. Everything else in the function is as it was.
--
-- MAP-2 · event_mapper_resolve_staged() — the daily wide GoTickets mapper (cron 548, 170 s statement timeout,
--   cap 1,000) timed out 4 of the last 7 nights. Measured 2026-11-17 on prod: the stage-3 hub lookup joins
--   tickets_dev_source_id to aq_event_map through an OR across four marketplace-id columns, which the planner
--   can only run as a sequential scan of the hub (17,827 rows, 71 ms); stage 9 repeats the same join. As a
--   UNION ALL of four single-column lookups the same answer comes back from the partial indexes
--   (idx_aq_event_map_sg/sh/vivid/tm, aq_event_map_gotickets_event_id_idx) in 22 ms. Semantics unchanged:
--   same marketplaces, same tevo_event_id IS NOT NULL filter, LIMIT 1; a non-numeric source id simply does not
--   match (the text comparison could not match a bigint column either). Rest of the body is prod's, verbatim.
--
-- MAP-4 · sg_canonical_verify_day() — SeatGeek -> EVO links on the wrong local day. Of 1,756 upcoming
--   tevo_search_autotrack links, 188 point at an EVO event on the previous or next night (matcher_v3_pm24h 16,
--   auto_canonical_loop 4): every evening US show once, through sg_event_date being a UTC date. The 2026-09-15
--   correction (sg_fix_wrong_night) was a one-off. This is the standing form: for every upcoming SeatGeek row
--   whose EVO event's local day differs from SeatGeek's own local day (raw datetime_local, else sg_event_date),
--   take the ONE EVO event at the same venue on SeatGeek's day with the same normalised name
--   (event_mapper_norm_name), unless another SeatGeek row already holds it. Repoint (match_method
--   'day_verifier', confidence 0.98), log to sg_night_correction_log (old and new ids, reversible), and keep the
--   hub honest the way sg_fix_wrong_night did (clear the stale sg_event_id on the old EVO event's row, set it
--   on the new one when free). Dry run 2026-11-17: 79 repointable, 9 refused (target held by another row).
--   Hourly at :26, after the SeatGeek mapper's :21 pass. p_apply=false reports and writes nothing.
--
-- MAP-6 · v_mapping_pipeline_health — "aq_tevo_bridge stalled" has fired every night with backlog 0: the bridge
--   is only "ok" when it MATCHES something, so a quiet night past 6 h reads as a stall. A stage with a backlog
--   column is now stalled only when its backlog is non-zero; stages without one keep the age rule.
--   (td_match_apply remains genuinely stalled: backlog 293, inactive since 2026-09-09 — an operator decision.)
--
-- Rollback: each function/view's previous definition is in migs 20260914220000 (venue xref), 20260915070000 +
--   later (staged cascade), 20260917000000 (health view); the verifier's writes reverse from
--   sg_night_correction_log.old_tevo_id where accept_rule = 'day_verifier'; cron.unschedule('sg_canonical_verify_hourly').

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ---------------------------------------------------------------------------------------------------------
-- MAP-3 · venue_xref_derive_from_events: one aq_venue_map target per marketplace venue id
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.venue_xref_derive_from_events(p_apply boolean DEFAULT true)
 RETURNS TABLE(source text, action text, n integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer; v_conflicts integer := 0; v_txt text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'venue_xref_derive_from_events: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;
  DROP TABLE IF EXISTS _sg, _tp, _gt;
  CREATE TEMP TABLE _sg ON COMMIT DROP AS
    SELECT e.venue_id AS tevo_venue_id,
           min((sgc.raw_event_jsonb->'venue'->>'id')::bigint) AS mp_id,
           count(*)::int AS ev
      FROM public.sg_events_canonical sgc
      JOIN public.events e ON e.id = sgc.tevo_event_id
     WHERE sgc.tevo_event_id IS NOT NULL
       AND e.venue_id IS NOT NULL
       AND sgc.raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$'
     GROUP BY e.venue_id
    HAVING count(DISTINCT (sgc.raw_event_jsonb->'venue'->>'id')::bigint) = 1;
  CREATE TEMP TABLE _tp ON COMMIT DROP AS
    SELECT e.venue_id AS tevo_venue_id,
           min((o.raw->'venue'->>'id')::bigint) AS mp_id,
           count(*)::int AS ev
      FROM public.tickpick_orders o
      JOIN public.events e ON e.id = o.tevo_event_id
     WHERE o.tevo_event_id IS NOT NULL
       AND e.venue_id IS NOT NULL
       AND o.raw->'venue'->>'id' ~ '^[0-9]+$'
     GROUP BY e.venue_id
    HAVING count(DISTINCT (o.raw->'venue'->>'id')::bigint) = 1;
  CREATE TEMP TABLE _gt ON COMMIT DROP AS
    SELECT x.tevo_venue_id, x.top_id AS mp_id, x.votes::int AS ev, round(x.top::numeric / x.votes, 3) AS share
      FROM (SELECT o.tevo_venue_id, sum(o.n) AS votes, max(o.n) AS top, count(*) AS n_ids,
                   (array_agg(o.gt_venue_id ORDER BY o.n DESC))[1] AS top_id
              FROM (SELECT e.venue_id AS tevo_venue_id, p.venue_id AS gt_venue_id, count(*) AS n
                      FROM (SELECT venue_id, tevo_event_id FROM public.gotickets_purchases
                             WHERE tevo_event_id IS NOT NULL AND venue_id IS NOT NULL
                            UNION ALL
                            SELECT s.venue_id, g.tevo_event_id FROM public.gotickets_sales s
                              JOIN public.gotickets_event g ON g.gt_event_id = s.gt_event_id
                             WHERE g.tevo_event_id IS NOT NULL AND s.venue_id IS NOT NULL) p
                      JOIN public.events e ON e.id = p.tevo_event_id AND e.venue_id IS NOT NULL
                     GROUP BY 1, 2) o
             GROUP BY o.tevo_venue_id) x
     WHERE x.n_ids = 1 OR (x.top::numeric / x.votes >= 0.9 AND x.votes >= 3);
  DELETE FROM _gt g WHERE EXISTS (SELECT 1 FROM _gt o WHERE o.mp_id = g.mp_id AND o.tevo_venue_id <> g.tevo_venue_id);
  SELECT count(*) INTO v_conflicts
    FROM (
      SELECT 1 FROM _sg s JOIN public.cross_source_venue_map m USING (tevo_venue_id)
        WHERE m.sg_venue_id IS NOT NULL AND m.sg_venue_id <> s.mp_id
      UNION ALL
      SELECT 1 FROM _tp t JOIN public.cross_source_venue_map m USING (tevo_venue_id)
        WHERE m.tickpick_venue_id IS NOT NULL AND m.tickpick_venue_id <> t.mp_id
      UNION ALL
      SELECT 1 FROM _gt g JOIN public.cross_source_venue_map m USING (tevo_venue_id)
        WHERE m.gotickets_venue_id IS NOT NULL AND m.gotickets_venue_id <> g.mp_id
    ) c;
  IF NOT p_apply THEN
    RETURN QUERY SELECT 'seatgeek'::text, 'derivable'::text, (SELECT count(*)::int FROM _sg);
    RETURN QUERY SELECT 'tickpick'::text, 'derivable'::text, (SELECT count(*)::int FROM _tp);
    RETURN QUERY SELECT 'gotickets'::text, 'derivable'::text, (SELECT count(*)::int FROM _gt);
    RETURN QUERY SELECT 'all'::text,      'conflicts'::text, v_conflicts;
    RETURN;
  END IF;
  WITH need AS (
    SELECT tevo_venue_id FROM _sg
    UNION
    SELECT tevo_venue_id FROM _tp
    UNION
    SELECT tevo_venue_id FROM _gt
  ), src AS (
    SELECT DISTINCT ON (e.venue_id)
           e.venue_id AS tevo_venue_id, e.venue_name, e.venue_location, e.state
      FROM public.events e JOIN need n ON n.tevo_venue_id = e.venue_id
     WHERE e.venue_name IS NOT NULL
     ORDER BY e.venue_id, e.id DESC
  )
  INSERT INTO public.cross_source_venue_map
        (tevo_venue_id, tevo_venue_name, tevo_venue_location, state)
  SELECT s.tevo_venue_id, s.venue_name, s.venue_location, s.state
    FROM src s
   WHERE NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                      WHERE m.tevo_venue_id = s.tevo_venue_id)
  ON CONFLICT (tevo_venue_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'all'::text, 'venues_inserted'::text, v_n;
  UPDATE public.cross_source_venue_map m
     SET sg_venue_id = s.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('sg',
           jsonb_build_object('method','event_agreement','events',s.ev,'derived_at',now())),
         updated_at = now()
    FROM _sg s
   WHERE m.tevo_venue_id = s.tevo_venue_id
     AND m.sg_venue_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'seatgeek'::text, 'ids_filled'::text, v_n;
  UPDATE public.cross_source_venue_map m
     SET tickpick_venue_id = t.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('tickpick',
           jsonb_build_object('method','event_agreement','events',t.ev,'derived_at',now())),
         updated_at = now()
    FROM _tp t
   WHERE m.tevo_venue_id = t.tevo_venue_id
     AND m.tickpick_venue_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'tickpick'::text, 'ids_filled'::text, v_n;
  UPDATE public.cross_source_venue_map m
     SET gotickets_venue_id = g.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('gotickets',
           jsonb_build_object('method','event_majority','events',g.ev,'share',g.share,'derived_at',now())),
         updated_at = now()
    FROM _gt g
   WHERE m.tevo_venue_id = g.tevo_venue_id
     AND m.gotickets_venue_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'gotickets'::text, 'ids_filled'::text, v_n;
  UPDATE public.cross_source_venue_map m
     SET venue_short_id = a.venue_short_id, updated_at = now()
    FROM (SELECT DISTINCT ON (tevo_venue_id) tevo_venue_id, venue_short_id FROM public.aq_venue_map
           WHERE tevo_venue_id IS NOT NULL AND venue_short_id IS NOT NULL ORDER BY tevo_venue_id, venue_short_id) a
   WHERE m.tevo_venue_id = a.tevo_venue_id AND m.venue_short_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'aq'::text, 'short_ids_filled'::text, v_n;
  -- mig 20261117020000 (MAP-3): one aq_venue_map row per marketplace venue id. cross_source_venue_map carries
  -- a SeatGeek id on more than one TEvo venue (18 on 2026-11-17); joining through tevo_venue_id handed the
  -- same id to two rows in one statement, past the NOT EXISTS guard, and the unique key refused it — the daily
  -- cron failed at this line for a week. DISTINCT ON the marketplace id picks one target; the others wait for a
  -- later derivation to disagree or agree.
  UPDATE public.aq_venue_map a
     SET sg_venue_id = s.sg_venue_id
    FROM (SELECT DISTINCT ON (m.sg_venue_id) m.sg_venue_id, a2.venue_short_id
            FROM public.cross_source_venue_map m
            JOIN public.aq_venue_map a2 ON a2.tevo_venue_id = m.tevo_venue_id
           WHERE m.sg_venue_id IS NOT NULL AND a2.sg_venue_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.sg_venue_id = m.sg_venue_id)
           ORDER BY m.sg_venue_id, a2.venue_short_id) s
   WHERE a.venue_short_id = s.venue_short_id AND a.sg_venue_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.aq_venue_map a
     SET tickpick_venue_id = s.tickpick_venue_id
    FROM (SELECT DISTINCT ON (m.tickpick_venue_id) m.tickpick_venue_id, a2.venue_short_id
            FROM public.cross_source_venue_map m
            JOIN public.aq_venue_map a2 ON a2.tevo_venue_id = m.tevo_venue_id
           WHERE m.tickpick_venue_id IS NOT NULL AND a2.tickpick_venue_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tickpick_venue_id = m.tickpick_venue_id)
           ORDER BY m.tickpick_venue_id, a2.venue_short_id) s
   WHERE a.venue_short_id = s.venue_short_id AND a.tickpick_venue_id IS NULL;
  GET DIAGNOSTICS v_txt = ROW_COUNT;
  RETURN QUERY SELECT 'aq'::text, 'aq_venue_map_ids_filled'::text, v_n + v_txt::int;
  WITH gt AS (
    SELECT e.venue_id AS tevo_venue_id,
           jsonb_agg(DISTINCT g.venue_name) AS aliases
      FROM public.gotickets_event g
      JOIN public.events e ON e.id = g.tevo_event_id
     WHERE g.tevo_event_id IS NOT NULL AND e.venue_id IS NOT NULL
       AND g.venue_name IS NOT NULL AND g.venue_name <> ''
     GROUP BY e.venue_id
  )
  UPDATE public.cross_source_venue_map m
     SET gotickets_aliases = gt.aliases, updated_at = now()
    FROM gt
   WHERE m.tevo_venue_id = gt.tevo_venue_id
     AND m.gotickets_aliases IS DISTINCT FROM gt.aliases;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'gotickets'::text, 'aliases_set'::text, v_n;
  RETURN QUERY SELECT 'all'::text, 'conflicts_not_overwritten'::text, v_conflicts;
  IF v_conflicts > 0 THEN
    PERFORM public.bot_chat_log(
      p_level      => 'data-collection',
      p_lane       => 'A1',
      p_event_type => 'flag',
      p_message    => format('venue_xref_derive_from_events: %s marketplace venue id(s) '
                          || 'disagree with a value already in cross_source_venue_map. The existing '
                          || 'value was KEPT. Adjudicate before trusting either.', v_conflicts));
  END IF;
END $function$;

-- ---------------------------------------------------------------------------------------------------------
-- MAP-2 · the hub's EVO event for a tickets.dev catalogue id — four indexed lookups, not one OR-join
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_mapper_tdev_hub_tevo(p_tdev text)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF p_tdev IS NULL THEN RETURN NULL; END IF;
  RETURN (
    SELECT x.tevo_event_id FROM (
      SELECT a.tevo_event_id FROM public.tickets_dev_source_id s
        JOIN public.aq_event_map a ON a.gotickets_event_id = CASE WHEN s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END
       WHERE s.tdev_id = p_tdev AND s.marketplace = 'gotickets' AND a.tevo_event_id IS NOT NULL
      UNION ALL
      SELECT a.tevo_event_id FROM public.tickets_dev_source_id s
        JOIN public.aq_event_map a ON a.vivid_event_id = CASE WHEN s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END
       WHERE s.tdev_id = p_tdev AND s.marketplace = 'vividseats' AND a.tevo_event_id IS NOT NULL
      UNION ALL
      SELECT a.tevo_event_id FROM public.tickets_dev_source_id s
        JOIN public.aq_event_map a ON a.sh_event_id = CASE WHEN s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END
       WHERE s.tdev_id = p_tdev AND s.marketplace = 'stubhub' AND a.tevo_event_id IS NOT NULL
      UNION ALL
      SELECT a.tevo_event_id FROM public.tickets_dev_source_id s
        JOIN public.aq_event_map a ON a.tm_event_id = CASE WHEN s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END
       WHERE s.tdev_id = p_tdev AND s.marketplace = 'ticketmaster' AND a.tevo_event_id IS NOT NULL
    ) x LIMIT 1);
END $function$;
COMMENT ON FUNCTION public.event_mapper_tdev_hub_tevo(text) IS
  'The hub''s tevo_event_id for a tickets.dev catalogue id: its GoTickets / Vivid / StubHub / Ticketmaster ids looked up one column at a time through the hub''s partial indexes (mig 20261117020000, MAP-2). Replaces an OR-join that scanned the hub.';

-- ---------------------------------------------------------------------------------------------------------
-- MAP-2 · event_mapper_resolve_staged: prod's body (md5 4412b4f6…), stages 3 and 9 through the helper, and the
--         stage-3 GoTickets catalogue lookup by id rather than by text (the text cast skipped the primary key)
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_mapper_resolve_staged(p_surface text, p_row_key text, p_source text, p_source_event_id bigint, p_name text, p_performer text, p_venue_name text, p_venue_city text, p_venue_state text, p_local_date date, p_event_time_utc timestamp with time zone, p_source_venue_id bigint DEFAULT NULL::bigint, p_source_performer_id text DEFAULT NULL::text, p_allow_identity boolean DEFAULT true, p_min_overlap numeric DEFAULT 0.5, p_allow_gt boolean DEFAULT true)
 RETURNS TABLE(tevo_event_id bigint, gt_event_id bigint, primary_source text, method text, score numeric, stage integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_src text := lower(trim(coalesce(p_source, '')));
  v_name text := coalesce(p_name, '');
  v_venue text := nullif(trim(coalesce(p_venue_name, '')), '');
  v_vid bigint; v_tevo bigint; v_meth text; v_score numeric; v_tdev text; v_gt bigint;
  v_day date; v_n int; v_nums_a text[]; v_nums_b text[]; v_vovl numeric; v_mkt text; rr record;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  IF coalesce(p_venue_name, '') ILIKE '%parking%' OR v_name ILIKE '%parking%'
     OR coalesce(p_performer, '') ILIKE '%parking%'
     OR v_name ~* '(parking|shuttle)' THEN
    RETURN;
  END IF;

  IF p_surface = 's4kcs_orders' AND p_row_key IS NOT NULL THEN
    SELECT x.tevo, x.meth INTO v_tevo, v_meth FROM (
      SELECT v.tevo_event_id AS tevo, 'order_id_vivid'::text AS meth, 1 AS pri
        FROM public.vivid_orders v
       WHERE v.vivid_order_id = p_row_key AND v.tevo_event_id IS NOT NULL
      UNION ALL
      SELECT t.tevo_event_id, 'order_id_tickpick', 2
        FROM public.tickpick_orders t
       WHERE t.tp_order_id = p_row_key AND t.tevo_event_id IS NOT NULL
      UNION ALL
      SELECT so.tevo_event_id, 'order_id_seatgeek', 3
        FROM public.seatgeek_orders so
       WHERE so.sg_order_id = p_row_key AND so.tevo_event_id IS NOT NULL
         AND so.sg_event_id IS NOT NULL
    ) x ORDER BY x.pri LIMIT 1;

    IF v_tevo IS NOT NULL AND p_local_date IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.events e
                        WHERE e.id = v_tevo AND left(e.occurs_at_local, 10) = p_local_date::text) THEN
      v_tevo := NULL; v_meth := NULL;
    END IF;

    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
      method := v_meth; score := 1.00; stage := 1; RETURN NEXT; RETURN;
    END IF;
  END IF;

  IF p_allow_identity THEN
    SELECT i.tevo_event_id, i.method INTO v_tevo, v_meth
      FROM public.event_mapper_identity(v_src, p_source_event_id) i;
    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
      method := v_meth; score := 1.00; stage := 2; RETURN NEXT; RETURN;
    END IF;
  END IF;

  IF v_name ~* '(\(date tbd\)|\btbd\b|if necessary)' THEN RETURN; END IF;

  IF p_source_venue_id IS NOT NULL THEN
    SELECT m.tevo_venue_id INTO v_vid FROM public.cross_source_venue_map m
     WHERE (v_src IN ('gotickets', 'gt') AND m.gotickets_venue_id = p_source_venue_id)
        OR (v_src IN ('seatgeek', 'sg')  AND m.sg_venue_id        = p_source_venue_id)
        OR (v_src IN ('tickpick', 'tp')  AND m.tickpick_venue_id  = p_source_venue_id)
     LIMIT 1;
  END IF;
  v_vid := coalesce(v_vid, public.cross_source_venue_resolve(p_venue_name, p_venue_city, p_venue_state));

  IF p_row_key IS NOT NULL THEN
    SELECT p.tdev_id INTO v_tdev FROM public.tickets_dev_row_probe p
     WHERE p.surface = p_surface AND p.row_key = p_row_key AND p.outcome = 'matched' LIMIT 1;
  END IF;
  IF v_tdev IS NULL AND p_source_event_id IS NOT NULL THEN
    v_mkt := CASE WHEN v_src IN ('vivid', 'vividseats', 'vivid seats') THEN 'vividseats'
                  WHEN v_src IN ('gotickets', 'gt')                    THEN 'gotickets'
                  WHEN v_src IN ('stubhub', 'sh')                      THEN 'stubhub'
                  WHEN v_src IN ('ticketmaster', 'tm')                 THEN 'ticketmaster'
                  ELSE NULL END;
    IF v_mkt IS NOT NULL THEN
      SELECT s.tdev_id INTO v_tdev FROM public.tickets_dev_source_id s
       WHERE s.marketplace = v_mkt AND s.source_event_id = p_source_event_id::text LIMIT 1;
    END IF;
  END IF;

  IF v_tdev IS NOT NULL THEN
    -- mig 20261117020000 (MAP-2): the GoTickets catalogue by its primary key, the hub through its partial indexes
    SELECT coalesce(
      (SELECT g.tevo_event_id FROM public.tickets_dev_source_id s
         JOIN public.gotickets_event g ON g.gt_event_id = CASE WHEN s.source_event_id ~ '^[0-9]+$' THEN s.source_event_id::bigint END
        WHERE s.tdev_id = v_tdev AND s.marketplace = 'gotickets' AND g.tevo_event_id IS NOT NULL LIMIT 1),
      public.event_mapper_tdev_hub_tevo(v_tdev)) INTO v_tevo;
    IF v_tevo IS NOT NULL THEN
      tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
      method := 'catalog_identity'; score := 0.96; stage := 3; RETURN NEXT; RETURN;
    END IF;
  END IF;

  SELECT r.tevo_event_id, r.method, r.score INTO v_tevo, v_meth, v_score
    FROM public.event_mapper_resolve_by_id(v_src, p_source_venue_id, p_local_date,
                                           p_source_performer_id, p_name) r;
  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
    method := v_meth; score := v_score; stage := 4; RETURN NEXT; RETURN;
  END IF;

  SELECT r.tevo_event_id, r.method, r.score INTO v_tevo, v_meth, v_score
    FROM public.event_mapper_resolve(v_src, p_source_event_id, p_name, p_performer, p_venue_name,
                                     p_venue_city, p_venue_state, p_local_date, p_event_time_utc,
                                     false, p_min_overlap, p_source_venue_id) r;
  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
    method := v_meth; score := v_score; stage := 5; RETURN NEXT; RETURN;
  END IF;

  IF p_event_time_utc IS NOT NULL AND v_vid IS NOT NULL THEN
    v_day := public.venue_local_day(v_vid, p_event_time_utc);
    IF v_day IS NOT NULL AND v_day IS DISTINCT FROM p_local_date THEN
      SELECT r.tevo_event_id, r.method, r.score INTO v_tevo, v_meth, v_score
        FROM public.event_mapper_resolve(v_src, p_source_event_id, p_name, p_performer, p_venue_name,
                                         p_venue_city, p_venue_state, v_day, NULL,
                                         false, p_min_overlap, p_source_venue_id) r;
      IF v_tevo IS NOT NULL THEN
        tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
        method := 'tz_' || coalesce(v_meth, 'day'); score := least(coalesce(v_score, 0.88), 0.88);
        stage := 6; RETURN NEXT; RETURN;
      END IF;
    END IF;
  END IF;

  IF v_tdev IS NOT NULL THEN
    SELECT t.venue_name, t.venue_city, t.venue_state, t.local_date INTO rr
      FROM public.tickets_dev_event t WHERE t.tdev_id = v_tdev LIMIT 1;
    IF rr.venue_name IS NOT NULL THEN
      SELECT r.tevo_event_id, r.method, r.score INTO v_tevo, v_meth, v_score
        FROM public.event_mapper_resolve(v_src, NULL, p_name, NULL, rr.venue_name,
                                         rr.venue_city, rr.venue_state,
                                         coalesce(p_local_date, rr.local_date), NULL,
                                         true, 0.5, NULL) r;
      IF v_tevo IS NOT NULL THEN
        tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
        method := 'catalog_venue'; score := coalesce(v_score, 0.80); stage := 7; RETURN NEXT; RETURN;
      END IF;
    END IF;
  END IF;

  IF p_local_date IS NOT NULL THEN
    SELECT count(*), min(e.id) INTO v_n, v_tevo
      FROM public.events e
     WHERE left(e.occurs_at_local, 10) = p_local_date::text
       AND coalesce(e.name, '') !~* 'parking|shuttle'
       AND public.event_mapper_overlap(public.event_mapper_norm_name(p_name),
                                       public.event_mapper_norm_name(e.name)) >= 0.7;
    IF v_n = 1 AND v_tevo IS NOT NULL THEN
      SELECT e.name AS ev_name, e.venue_name AS ev_venue,
             public.event_mapper_overlap(public.event_mapper_norm_name(p_name),
                                         public.event_mapper_norm_name(e.name)) AS ev_ovl
        INTO rr FROM public.events e WHERE e.id = v_tevo;
      SELECT coalesce(array_agg(m ORDER BY m), '{}') INTO v_nums_a
        FROM regexp_matches(coalesce(p_name, ''), '\d+', 'g') AS t(m2), unnest(t.m2) AS m;
      SELECT coalesce(array_agg(m ORDER BY m), '{}') INTO v_nums_b
        FROM regexp_matches(coalesce(rr.ev_name, ''), '\d+', 'g') AS t(m2), unnest(t.m2) AS m;
      v_vovl := CASE WHEN v_venue IS NULL THEN NULL
                     ELSE public.event_mapper_overlap(public.event_mapper_norm_name(v_venue),
                                                      public.event_mapper_norm_name(rr.ev_venue)) END;
      IF NOT (array_length(v_nums_a, 1) IS NOT NULL AND array_length(v_nums_b, 1) IS NOT NULL
              AND v_nums_a <> v_nums_b)
         AND NOT (v_vovl IS NOT NULL AND v_vovl < 0.3) THEN
        tevo_event_id := v_tevo; gt_event_id := NULL; primary_source := 'tevo';
        method := 'unique_same_day'; score := round(coalesce(rr.ev_ovl, 0.70), 2);
        stage := 8; RETURN NEXT; RETURN;
      END IF;
    END IF;
    v_tevo := NULL;
  END IF;

  IF p_allow_gt AND v_tdev IS NOT NULL THEN
    SELECT t.venue_name, t.local_date,
           (SELECT s.source_event_id::bigint FROM public.tickets_dev_source_id s
             WHERE s.tdev_id = v_tdev AND s.marketplace = 'gotickets'
               AND s.source_event_id ~ '^[0-9]+$' LIMIT 1) AS gt_id
      INTO rr FROM public.tickets_dev_event t WHERE t.tdev_id = v_tdev LIMIT 1;
    v_gt := rr.gt_id;
    IF v_gt IS NOT NULL AND rr.local_date IS NOT NULL AND rr.venue_name IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g
                        WHERE g.gt_event_id = v_gt AND g.tevo_event_id IS NOT NULL)
       AND public.event_mapper_tdev_hub_tevo(v_tdev) IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.events e
                        WHERE lower(trim(e.venue_name)) = lower(trim(rr.venue_name))
                          AND left(e.occurs_at_local, 10) = rr.local_date::text)
       AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                         JOIN public.events e ON e.venue_id = m.tevo_venue_id
                        WHERE lower(trim(m.canonical_name)) = lower(trim(rr.venue_name))
                          AND left(e.occurs_at_local, 10) = rr.local_date::text)
    THEN
      tevo_event_id := NULL; gt_event_id := v_gt; primary_source := 'gotickets';
      method := 'gt_primary'; score := 0.90; stage := 9; RETURN NEXT; RETURN;
    END IF;
  END IF;

  RETURN;
END $function$;

-- ---------------------------------------------------------------------------------------------------------
-- MAP-4 · sg_canonical_verify_day: a SeatGeek -> EVO link lives on SeatGeek's own local day
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sg_canonical_verify_day(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE v_repointed int := 0; v_cleared int := 0; v_set int := 0; v_by jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  DROP TABLE IF EXISTS _sgv;
  CREATE TEMP TABLE _sgv ON COMMIT DROP AS
  WITH cur AS (
    SELECT c.sg_event_id, c.sg_event_name, c.tevo_event_id AS old_tevo, c.match_method AS old_method,
           coalesce(CASE WHEN c.raw_event_jsonb->>'datetime_local' ~ '^\d{4}-\d{2}-\d{2}' THEN left(c.raw_event_jsonb->>'datetime_local', 10)::date END,
                    c.sg_event_date) AS sg_day,
           e.venue_id, e.name AS old_name, left(e.occurs_at_local, 10)::date AS old_day,
           public.event_mapper_norm_name(e.name) AS nn
      FROM public.sg_events_canonical c
      JOIN public.events e ON e.id = c.tevo_event_id
     WHERE c.sg_event_date >= current_date - 1 AND c.tevo_event_id IS NOT NULL AND e.venue_id IS NOT NULL),
  cand AS (
    SELECT cur.sg_event_id, cur.sg_event_name, cur.old_tevo, cur.old_method, cur.sg_day, cur.venue_id, cur.old_name, cur.old_day,
           min(e2.id) AS new_tevo, count(*) AS n_new
      FROM cur
      JOIN public.events e2 ON e2.venue_id = cur.venue_id
                           AND left(e2.occurs_at_local, 10) = cur.sg_day::text
                           AND coalesce(e2.state, 'shown') <> 'ignored'
                           AND public.event_mapper_norm_name(e2.name) = cur.nn
     WHERE cur.old_day <> cur.sg_day
     GROUP BY cur.sg_event_id, cur.sg_event_name, cur.old_tevo, cur.old_method, cur.sg_day, cur.venue_id, cur.old_name, cur.old_day)
  SELECT cand.*,
         (SELECT e3.name FROM public.events e3 WHERE e3.id = cand.new_tevo) AS new_name,
         CASE WHEN cand.n_new > 1 THEN 'ambiguous'
              WHEN EXISTS (SELECT 1 FROM public.sg_events_canonical o
                            WHERE o.tevo_event_id = cand.new_tevo AND o.sg_event_id <> cand.sg_event_id) THEN 'target_held'
              ELSE 'repoint' END AS act
    FROM cand;

  IF p_apply THEN
    INSERT INTO public.sg_night_correction_log (sg_event_id, sg_event_name, sg_local_day, old_tevo_id, old_event_name, old_local_day,
                                                new_tevo_id, new_event_name, accept_rule, ovl_old, ovl_new, corrected_at)
    SELECT v.sg_event_id, v.sg_event_name, v.sg_day, v.old_tevo, v.old_name, v.old_day, v.new_tevo, v.new_name, 'day_verifier', NULL, NULL, now()
      FROM _sgv v WHERE v.act = 'repoint'
    ON CONFLICT (sg_event_id) DO UPDATE
       SET sg_local_day = EXCLUDED.sg_local_day, old_tevo_id = EXCLUDED.old_tevo_id, old_event_name = EXCLUDED.old_event_name,
           old_local_day = EXCLUDED.old_local_day, new_tevo_id = EXCLUDED.new_tevo_id, new_event_name = EXCLUDED.new_event_name,
           accept_rule = 'day_verifier', corrected_at = now();

    UPDATE public.sg_events_canonical c
       SET tevo_event_id = v.new_tevo, match_method = 'day_verifier', match_confidence = 0.98, matched_at = now(), updated_at = now()
      FROM _sgv v
     WHERE c.sg_event_id = v.sg_event_id AND c.tevo_event_id = v.old_tevo AND v.act = 'repoint';
    GET DIAGNOSTICS v_repointed = ROW_COUNT;

    -- the hub, or identity re-asserts the old answer on the next mapper run (as sg_fix_wrong_night did)
    UPDATE public.aq_event_map a SET sg_event_id = NULL
      FROM _sgv v
     WHERE a.sg_event_id = v.sg_event_id AND a.tevo_event_id = v.old_tevo AND v.act = 'repoint';
    GET DIAGNOSTICS v_cleared = ROW_COUNT;
    UPDATE public.aq_event_map a SET sg_event_id = v.sg_event_id
      FROM _sgv v
     WHERE a.tevo_event_id = v.new_tevo AND a.sg_event_id IS NULL AND v.act = 'repoint'
       AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o
                        WHERE o.sg_event_id = v.sg_event_id AND o.tevo_event_id IS DISTINCT FROM v.new_tevo);
    GET DIAGNOSTICS v_set = ROW_COUNT;
  END IF;

  SELECT coalesce(jsonb_object_agg(x.old_method, x.n), '{}'::jsonb) INTO v_by
    FROM (SELECT coalesce(old_method, '?') AS old_method, count(*) AS n FROM _sgv WHERE act = 'repoint' GROUP BY 1) x;
  RETURN jsonb_build_object('applied', p_apply,
           'off_day', (SELECT count(*) FROM _sgv),
           'repointable', (SELECT count(*) FROM _sgv WHERE act = 'repoint'),
           'ambiguous', (SELECT count(*) FROM _sgv WHERE act = 'ambiguous'),
           'target_held', (SELECT count(*) FROM _sgv WHERE act = 'target_held'),
           'repointed', v_repointed, 'hub_cleared', v_cleared, 'hub_set', v_set, 'by_old_method', v_by);
END $function$;

REVOKE ALL ON FUNCTION public.event_mapper_tdev_hub_tevo(text), public.sg_canonical_verify_day(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_tdev_hub_tevo(text), public.sg_canonical_verify_day(boolean) TO service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sg_canonical_verify_hourly') THEN
    PERFORM cron.unschedule('sg_canonical_verify_hourly');
  END IF;
  PERFORM cron.schedule('sg_canonical_verify_hourly', '26 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '120s'; SELECT public.sg_canonical_verify_day(true); COMMIT;$j$);
END
$cron$;

-- ---------------------------------------------------------------------------------------------------------
-- MAP-6 · v_mapping_pipeline_health: a stage with a backlog column is stalled only when something is waiting
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_mapping_pipeline_health AS
WITH p AS (
  SELECT 'crm_ingest'::text AS pipeline,
         (SELECT max(s4kcs_orders.pulled_at) FROM public.s4kcs_orders) AS last_ok,
         '00:30:00'::interval AS max_age, NULL::bigint AS backlog
  UNION ALL
  SELECT 'crm_event_mapper'::text,
         (SELECT max(s4kcs_orders.mapped_at) FROM public.s4kcs_orders),
         '02:00:00'::interval,
         (SELECT count(*) FROM public.s4kcs_orders WHERE s4kcs_orders.tevo_event_id IS NULL AND s4kcs_orders.event_date >= CURRENT_DATE)
  UNION ALL
  SELECT 'aq_tevo_bridge'::text,
         (SELECT max(aq_tevo_search_attempts.attempted_at) FROM public.aq_tevo_search_attempts WHERE aq_tevo_search_attempts.result = 'matched'::text),
         '06:00:00'::interval,
         (SELECT count(*) FROM public.aq_event_map m
            LEFT JOIN public.aq_tevo_search_attempts a ON a.aq_id = m.id
           WHERE m.tevo_event_id IS NULL AND m.sg_event_id IS NULL AND m.event_date >= now()::timestamp without time zone
             AND NOT ((m.category = ANY (ARRAY['Parking'::text, 'parking'::text])) OR m.venue_name ~~* '%parking%'::text OR m.event_name ~~* '%parking%'::text)
             AND NOT m.event_name ~* '(cancelled|if necessary|\(date tbd\))'::text
             AND NOT m.event_name ~* 'season tickets?'::text
             AND (a.aq_id IS NULL OR a.attempted_at < (now() - '24:00:00'::interval)))
  UNION ALL
  SELECT 'td_match_apply'::text,
         (SELECT max(td_match_results.applied_at) FROM public.td_match_results),
         '48:00:00'::interval,
         (SELECT count(*) FROM public.td_match_results WHERE td_match_results.applied_at IS NULL)
  UNION ALL
  SELECT 'vivid_orders'::text, (SELECT max(vivid_orders.pulled_at) FROM public.vivid_orders), '24:00:00'::interval, NULL::bigint
  UNION ALL
  SELECT 'tickpick_orders'::text, (SELECT max(tickpick_orders.pulled_at) FROM public.tickpick_orders), '24:00:00'::interval, NULL::bigint
  UNION ALL
  SELECT 'seatgeek_seller'::text, (SELECT max(sg_seller_pending.resolved_at) FROM public.sg_seller_pending), '02:00:00'::interval, NULL::bigint
)
SELECT pipeline, last_ok, now() - last_ok AS age, max_age, backlog,
       -- mig 20261117020000 (MAP-6): a stage that reports a backlog is stalled only when that backlog is non-zero;
       -- a quiet night is not a stall. Stages without a backlog keep the age rule.
       (last_ok IS NULL OR ((now() - last_ok) > max_age AND coalesce(backlog, 1) > 0)) AS stalled
  FROM p;

COMMIT;

-- VERIFY:
--   SELECT * FROM venue_xref_derive_from_events(false);                       -- then the 06:23 cron succeeds
--   SELECT * FROM sg_canonical_verify_day(false);                              -- counts; the :26 cron applies
--   SELECT * FROM v_mapping_pipeline_health;                                   -- aq_tevo_bridge no longer stalled at backlog 0
--   next 08:50 run of cron 548: SELECT status, end_time-start_time FROM cron.job_run_details WHERE jobid = 548 ORDER BY start_time DESC LIMIT 1;
