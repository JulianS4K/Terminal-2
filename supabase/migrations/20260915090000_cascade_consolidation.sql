-- Retire the post-passes into the cascade, and make GoTickets keying obey it.
--
-- Operator: "fix both" -- the first being the duplication mig 20260915070000 shipped with and
-- named rather than hid: stages 3/7/8/9 restated tickets_dev_apply_hints,
-- s4kcs_fill_unique_same_day and event_mapper_gt_fallback.
--
-- That migration said consolidation was gated on WATCHING the cascade cover those rows rather
-- than assuming it. It has now been watched, so here are the numbers it was waiting for:
--
--   s4kcs_fill_unique_same_day        wants to map   0 rows  -> stage 8 absorbed it entirely
--   tickets_dev_apply_hints(sg)       proposes       0 rows  -> stages 3/7 absorbed it
--   tickets_dev_apply_hints(s4kcs)    proposes      45 rows  -- but ALL 45 are on rows that are
--                                                              already mapped, and it writes
--                                                              `WHERE tevo_event_id IS NULL`, so
--                                                              all 45 are no-ops.
--
-- Both are therefore unscheduled below. They are NOT dropped: the functions remain callable by
-- hand, which keeps a way back if the cascade ever regresses.

---------------------------------------------------------------------------------------------
-- 1. Two changes to the cascade itself.
--
-- (a) SEATGEEK RETURNS TO STAGE 1, under a condition it can now satisfy.
--     mig 20260915070000 threw seatgeek_orders out of stage 1 because parity showed 7 of 12 of
--     its answers wrong, and measured the cause: only 53% of its future mapped rows sat on the
--     TEvo event's own local day. mig 20260915080000 then found why -- a foreign key meant an
--     order for an uncatalogued SeatGeek event could not store its own event id, so it fell
--     back to a fuzzy aq_short_event_id guess -- recovered 1,617 ids and re-pointed 627 bindings.
--     The book now splits cleanly in two:
--
--         rows WITH a recovered id   769 mapped, 768 on the right day = 99.9%
--         rows still without one     193 mapped, 117 on the right day = 60.6%
--
--     So the id, not the book, is what makes the claim trustworthy, and the condition is exactly
--     that: seatgeek answers stage 1 only where sg_event_id IS NOT NULL. The date
--     non-contradiction guard added in 20260915070000 still applies on top as a second net.
--     gotickets and evo stay out -- their measured yield for CRM rows was 0 and 0, so there is
--     nothing to weigh against the risk.
--
-- (b) THE CLUSTER LOOKUP LEARNS THE SECOND ROUTE. v_tdev was found only through
--     tickets_dev_row_probe, which exists for name-searched surfaces (s4kcs, sg_events_canonical,
--     tickpick) and NOT for vivid_orders, whose clusters are reached by marketplace id. Without
--     this, delegating gt_fallback to stage 9 would have silently stopped keying every vivid row
--     -- a regression dressed as a consolidation. Stages 3 and 7 gain the same reach.
---------------------------------------------------------------------------------------------

-- (see mig 20260915070000 for the full stage-by-stage commentary; only the two blocks above change)
CREATE OR REPLACE FUNCTION public.event_mapper_resolve_staged(
  p_surface text, p_row_key text, p_source text, p_source_event_id bigint,
  p_name text, p_performer text, p_venue_name text, p_venue_city text, p_venue_state text,
  p_local_date date, p_event_time_utc timestamptz, p_source_venue_id bigint DEFAULT NULL,
  p_source_performer_id text DEFAULT NULL, p_allow_identity boolean DEFAULT true,
  p_min_overlap numeric DEFAULT 0.5, p_allow_gt boolean DEFAULT true)
RETURNS TABLE(tevo_event_id bigint, gt_event_id bigint, primary_source text,
              method text, score numeric, stage int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
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

  -- STAGE 1 -- order-number identity. seatgeek is admitted ONLY where the order carries its own
  -- SeatGeek event id (99.9% day-accurate); without one it is the 60.6% fuzzy path and stays out.
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

  -- the cluster, by either route: the name-search probe, or this source's own marketplace id.
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
    SELECT coalesce(
      (SELECT g.tevo_event_id FROM public.tickets_dev_source_id s
         JOIN public.gotickets_event g ON g.gt_event_id::text = s.source_event_id
        WHERE s.tdev_id = v_tdev AND s.marketplace = 'gotickets' AND g.tevo_event_id IS NOT NULL LIMIT 1),
      (SELECT a.tevo_event_id FROM public.tickets_dev_source_id s
         JOIN public.aq_event_map a
           ON (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
           OR (s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
           OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
           OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)
        WHERE s.tdev_id = v_tdev AND a.tevo_event_id IS NOT NULL LIMIT 1)) INTO v_tevo;
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
       AND NOT EXISTS (SELECT 1 FROM public.tickets_dev_source_id s
                         JOIN public.aq_event_map a
                           ON (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
                           OR (s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
                           OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
                           OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)
                        WHERE s.tdev_id = v_tdev AND a.tevo_event_id IS NOT NULL)
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
END $fn$;

---------------------------------------------------------------------------------------------
-- 2. GoTickets keying now OBEYS the cascade instead of running beside it.
--
-- The old body re-implemented stage 9's guards and applied them to every catalogue cluster. What
-- it never asked was the one question that defines a fallback: did any TEvo route succeed? Its
-- guards test the CLUSTER (no sibling id resolves, the mirror has nothing at that venue that
-- day), not the ROW, so a row TEvo could reach by a different venue spelling or by name alone was
-- still eligible to be demoted to a GoTickets key and stranded there.
--
-- Measured before changing it: of 111 rows it wanted to key on s4kcs, the cascade maps 1 to a
-- TEvo event. Small, but it is the exact failure the operator's "gotickets as secondary fallback"
-- rules out, and it is structural rather than incidental -- so it is fixed structurally. The
-- decision now has ONE definition (stage 9) and this function is only its writer: it keys a row
-- if and only if resolve_staged returns stage 9 for it, which by construction means stages 1-8
-- all declined first.
--
-- The writer itself is unchanged: same GT-<id> key, same hub upsert with tevo_event_id left NULL
-- on purpose (the deal scanner, listings, pricing and N2S cover all join on that column, and a
-- foreign id there would corrupt every one of them silently), same per-surface column.
--
-- COST, and why there is a per-tick cap. Asking the cascade per row is not cheap: stage 5 ends in
-- match_to_aq_event_id, whose similarity() scan over aq_event_map is the single most expensive
-- thing in the mapper, and these candidates are TEvo-absent by construction so they always run it
-- to completion before declining. The first version of this function ran the cascade over 2,000
-- rows per surface and blew the tick budget outright; even after the bulk pre-filter below, 259
-- clusters survive and one surface's share costs tens of seconds.
--
-- So the confirmation is capped at GT_FALLBACK_TICK_CAP rows per surface per tick. This is a
-- maintenance pass on a 15-minute cron, not a latency path: the backlog drains over a few ticks
-- and steady state is near zero. The cap is on the CONFIRMATION, never on the guards -- no row is
-- keyed without the cascade having declined it through stages 1-8.
CREATE OR REPLACE FUNCTION public.event_mapper_gt_fallback(p_surface text, p_apply boolean DEFAULT false)
RETURNS TABLE(out_row_key text, out_gt_event_id bigint, out_aq_key text, out_event_name text,
              out_venue text, out_local_day date, out_action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_sel text; rr record; v_key text; c_tick_cap constant int := 30;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '160000', true);

  IF p_surface NOT IN ('s4kcs_orders', 'vivid_orders', 'tickpick_orders', 'sg_events_canonical') THEN
    RAISE EXCEPTION 'event_mapper_gt_fallback: unsupported surface %', p_surface;
  END IF;

  DROP TABLE IF EXISTS _gtc;
  CREATE TEMP TABLE _gtc ON COMMIT DROP AS
  SELECT t.tdev_id, t.name, t.local_date, t.venue_name, t.venue_city, t.venue_state,
         (SELECT s.source_event_id::bigint FROM public.tickets_dev_source_id s
           WHERE s.tdev_id = t.tdev_id AND s.marketplace = 'gotickets'
             AND s.source_event_id ~ '^[0-9]+$' LIMIT 1) AS gt_id
    FROM public.tickets_dev_event t
   WHERE t.local_date IS NOT NULL AND t.venue_name IS NOT NULL;
  DELETE FROM _gtc WHERE gt_id IS NULL;

  DELETE FROM _gtc c
   WHERE EXISTS (SELECT 1 FROM public.gotickets_event g
                  WHERE g.gt_event_id = c.gt_id AND g.tevo_event_id IS NOT NULL)
      OR EXISTS (SELECT 1 FROM public.tickets_dev_source_id s
                   JOIN public.aq_event_map a
                     ON (s.marketplace = 'gotickets'    AND a.gotickets_event_id::text = s.source_event_id)
                     OR (s.marketplace = 'vividseats'   AND a.vivid_event_id::text     = s.source_event_id)
                     OR (s.marketplace = 'stubhub'      AND a.sh_event_id::text        = s.source_event_id)
                     OR (s.marketplace = 'ticketmaster' AND a.tm_event_id::text        = s.source_event_id)
                  WHERE s.tdev_id = c.tdev_id AND a.tevo_event_id IS NOT NULL)
      OR EXISTS (SELECT 1 FROM public.events e
                  WHERE lower(trim(e.venue_name)) = lower(trim(c.venue_name))
                    AND left(e.occurs_at_local, 10) = c.local_date::text)
      OR EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                   JOIN public.events e ON e.venue_id = m.tevo_venue_id
                  WHERE lower(trim(m.canonical_name)) = lower(trim(c.venue_name))
                    AND left(e.occurs_at_local, 10) = c.local_date::text);

  SELECT s.select_sql INTO v_sel FROM public.event_mapper_surface_sql(p_surface) s;
  DROP TABLE IF EXISTS _gtr;
  EXECUTE format(
    'CREATE TEMP TABLE _gtr ON COMMIT DROP AS SELECT * FROM (%s) q WHERE q.previous IS NULL LIMIT 2000',
    v_sel);

  DROP TABLE IF EXISTS _gtn;
  EXECUTE format($q$
    CREATE TEMP TABLE _gtn ON COMMIT DROP AS
    SELECT r.*, c.tdev_id, c.gt_id, c.name AS td_name, c.venue_name AS td_venue,
           c.venue_city AS td_city, c.venue_state AS td_state, c.local_date AS td_day
      FROM _gtr r
      JOIN _gtc c ON c.tdev_id = coalesce(
             (SELECT p.tdev_id FROM public.tickets_dev_row_probe p
               WHERE p.surface = %L AND p.row_key = r.row_key AND p.outcome = 'matched' LIMIT 1),
             (SELECT s2.tdev_id FROM public.tickets_dev_source_id s2
               WHERE s2.source_event_id = r.source_event_id::text
                 AND s2.marketplace = CASE
                       WHEN lower(r.source) IN ('vivid','vividseats','vivid seats') THEN 'vividseats'
                       WHEN lower(r.source) IN ('gotickets','gt')                   THEN 'gotickets'
                       WHEN lower(r.source) IN ('stubhub','sh')                     THEN 'stubhub'
                       WHEN lower(r.source) IN ('ticketmaster','tm')                THEN 'ticketmaster'
                       ELSE NULL END
               LIMIT 1))
     LIMIT %s$q$, p_surface, c_tick_cap);

  FOR rr IN
    SELECT n.row_key, n.gt_id, n.td_name, n.td_venue, n.td_city, n.td_state, n.td_day
      FROM _gtn n
      JOIN LATERAL public.event_mapper_resolve_staged(
             p_surface, n.row_key, n.source, n.source_event_id, n.event_name, n.performer,
             n.venue_name, n.venue_city, n.venue_state, n.local_date, n.event_time_utc,
             n.source_venue_id, n.source_performer_id, true, 0.5, true) st ON st.stage = 9
  LOOP
    v_key := 'GT-' || rr.gt_id::text;

    IF p_apply THEN
      INSERT INTO public.aq_event_map (aq_short_event_id, event_name, venue_name, city, state,
                                       event_date, gotickets_event_id, primary_source, aq_source, imported_at)
      VALUES (v_key, rr.td_name, rr.td_venue, rr.td_city, rr.td_state,
              rr.td_day::timestamp, rr.gt_id, 'gotickets', 'gotickets_primary', now())
      ON CONFLICT (aq_short_event_id) DO UPDATE
        SET gotickets_event_id = coalesce(public.aq_event_map.gotickets_event_id, excluded.gotickets_event_id),
            primary_source = coalesce(public.aq_event_map.primary_source, 'gotickets'),
            event_name = coalesce(public.aq_event_map.event_name, excluded.event_name),
            venue_name = coalesce(public.aq_event_map.venue_name, excluded.venue_name);

      IF p_surface = 's4kcs_orders' THEN
        UPDATE public.s4kcs_orders SET aq_short_event_id = v_key
         WHERE s4k_order_id = rr.row_key AND tevo_event_id IS NULL AND aq_short_event_id IS DISTINCT FROM v_key;
      ELSIF p_surface = 'vivid_orders' THEN
        UPDATE public.vivid_orders SET aq_short_event_id = v_key
         WHERE vivid_order_id = rr.row_key AND tevo_event_id IS NULL AND aq_short_event_id IS DISTINCT FROM v_key;
      ELSIF p_surface = 'tickpick_orders' THEN
        UPDATE public.tickpick_orders SET aq_short_event_id = v_key
         WHERE tp_order_id = rr.row_key AND tevo_event_id IS NULL AND aq_short_event_id IS DISTINCT FROM v_key;
      END IF;
    END IF;

    out_row_key := rr.row_key; out_gt_event_id := rr.gt_id; out_aq_key := v_key;
    out_event_name := rr.td_name; out_venue := rr.td_venue; out_local_day := rr.td_day;
    out_action := CASE WHEN p_apply THEN 'keyed' ELSE 'would_key' END;
    RETURN NEXT;
  END LOOP;
END $fn$;

COMMENT ON FUNCTION public.event_mapper_gt_fallback(text, boolean) IS
  'WRITER for cascade stage 9. Keys a row to GT-<gotickets_event_id> with tevo_event_id left NULL, if and only if event_mapper_resolve_staged returns stage 9 for it -- which means every TEvo stage declined first. Holds no matching rules of its own (mig 20260915090000).';

---------------------------------------------------------------------------------------------
-- 3. Unschedule the two absorbed post-passes. Everything else in the tick is unchanged.
---------------------------------------------------------------------------------------------
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
      PERFORM public.tickets_dev_search_harvest();
      -- tickets_dev_apply_hints and s4kcs_fill_unique_same_day retired here: cascade stages 3, 7
      -- and 8 absorbed them (measured 0 writes each before removal, see this migration's header).
      -- Both remain callable by hand if the cascade ever needs to be second-guessed.
      PERFORM public.seatgeek_orders_recover_event_id(true);
      -- stage 9's writer, after every TEvo route has had its turn
      PERFORM public.event_mapper_gt_fallback('s4kcs_orders', true);
      PERFORM public.event_mapper_gt_fallback('vivid_orders', true);
      PERFORM public.event_mapper_gt_fallback('tickpick_orders', true);
      PERFORM public.event_mapper_gt_fallback('sg_events_canonical', true);
      PERFORM public.tickets_dev_search_enqueue('s4kcs_orders', 60);
      PERFORM public.tickets_dev_search_enqueue('sg_events_canonical', 60);
      PERFORM public.venue_xref_derive_by_id(true);
      PERFORM public.performer_xref_derive_from_events(true);
    END $b$; COMMIT;$body$);
END $cron$;
