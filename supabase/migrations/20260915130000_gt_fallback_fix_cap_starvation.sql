-- event_mapper_gt_fallback's per-tick cap was starving itself. Fourth time this pattern has bitten.
--
-- Caught by a scheduled health check, not by CI, and the symptom is the one that hides: the cron
-- SUCCEEDS every tick while achieving nothing. Over four consecutive ticks
-- aq_event_map.primary_source='gotickets' sat at exactly 144 while the function proposed a full
-- 30 rows every time. Both facts are true at once because all 30 proposals were rows that had
-- ALREADY been keyed, so every write was a no-op.
--
-- WHY. mig 20260915090000 added `LIMIT c_tick_cap` to the _gtn candidate table to stop the
-- cascade confirmation blowing the tick budget. What it did not add was any notion of "already
-- done". A row keyed to GT-<id> still has tevo_event_id IS NULL -- that is the whole point of
-- GoTickets-primary keying -- so it still satisfies `previous IS NULL` in the surface select, it
-- still joins a surviving cluster, and with no ORDER BY and no done-filter the unordered LIMIT 30
-- kept handing back the same finished head forever. Rows that still needed keying sat behind it
-- and could never be reached.
--
-- This is precisely the failure mig 20260915011000 documented for tickets_dev_fill_outward, and
-- mig 20260915060000 documented for tickets_dev_search_enqueue, and mig 20260915090000's own
-- header restated as a lesson: "a cap on an ordered list whose head is exhausted is not a cap, it
-- is a wall." Writing that sentence did not stop me applying a cap without a done-filter in the
-- same migration. The rule is worth stating operationally rather than as an aphorism:
--
--     ANY per-tick cap MUST be applied AFTER the predicate that removes finished work,
--     never before it, and the "finished" test must be the one the WRITER actually uses.
--
-- THE FIX. _gtn now excludes rows that are already keyed to the very GT id being proposed, before
-- the LIMIT, using the same condition the writer uses per surface:
--   * s4kcs_orders / vivid_orders / tickpick_orders -> the surface row's aq_short_event_id
--   * sg_events_canonical -> that surface has no per-row key column (the writer only upserts the
--     hub row), so "done" is the hub row for that GT id already existing.
-- An ORDER BY local_date is added so the drain is deterministic and oldest-first rather than
-- whatever order the join happens to produce.
--
-- Now that only unkeyed rows are returned, starvation is visible in the return value itself: a
-- run that yields fewer rows than the cap means the backlog is genuinely drained, and a run that
-- yields the full cap forever means there is still work. Under the old body those two states were
-- indistinguishable, which is exactly why this went unnoticed for an hour.
CREATE OR REPLACE FUNCTION public.event_mapper_gt_fallback(p_surface text, p_apply boolean DEFAULT false)
RETURNS TABLE(out_row_key text, out_gt_event_id bigint, out_aq_key text, out_event_name text,
              out_venue text, out_local_day date, out_action text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_sel text; rr record; v_key text; v_done text; c_tick_cap constant int := 30;
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

  -- the "already done" test, per surface, matching exactly what the writer below does
  v_done := CASE p_surface
    WHEN 's4kcs_orders'    THEN 'EXISTS (SELECT 1 FROM public.s4kcs_orders x
                                          WHERE x.s4k_order_id = r.row_key
                                            AND x.aq_short_event_id = ''GT-'' || c.gt_id::text)'
    WHEN 'vivid_orders'    THEN 'EXISTS (SELECT 1 FROM public.vivid_orders x
                                          WHERE x.vivid_order_id = r.row_key
                                            AND x.aq_short_event_id = ''GT-'' || c.gt_id::text)'
    WHEN 'tickpick_orders' THEN 'EXISTS (SELECT 1 FROM public.tickpick_orders x
                                          WHERE x.tp_order_id = r.row_key
                                            AND x.aq_short_event_id = ''GT-'' || c.gt_id::text)'
    ELSE                        'EXISTS (SELECT 1 FROM public.aq_event_map a2
                                          WHERE a2.aq_short_event_id = ''GT-'' || c.gt_id::text)'
  END;

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
     WHERE NOT %s
     ORDER BY c.local_date
     LIMIT %s$q$, p_surface, v_done, c_tick_cap);

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
  'WRITER for cascade stage 9. Keys a row to GT-<gotickets_event_id> iff event_mapper_resolve_staged returns stage 9 for it. The per-tick cap is applied AFTER excluding rows already keyed to that GT id, so it cannot re-propose finished work and starve the backlog (mig 20260915130000).';
