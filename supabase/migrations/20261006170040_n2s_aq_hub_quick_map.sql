-- Migration 20261006170040 · level:secondary-sales · lane:D7 (writes A1's aq_event_map, operator-routed) · writes:aq_event_map,n2s_items,n2s_hub_quick_map,n2s_aq_hub_writeback,n2s_crm_fetch_direct,n2s_pipeline_tick · reads:aq_event_map,events,n2s_items · pre:20260928190000
--
-- Already applied to prod · via MCP 2026-10-06 ~17:21 UTC under operator direction
-- ("use the automatiq table as the lookup table; build 2-3"), after a rolled-back
-- dry run: the last 7 days of mapped orders (708) were un-mapped and re-mapped
-- through the hub — 569 got the same event as the matcher, 0 a different one,
-- 139 declined (left to the matcher); 1.3 s for all 708, 12 ms for the per-tick
-- call; write-back 0 rows (the hub already held every event); both hooks present;
-- prod unchanged afterwards. Both crons ran clean after the apply.
-- Renumbered from 20261006170000 (prefix collided with 20261006170000_d0_pickups_pace);
-- the function bodies and COMMENTs in prod carry the original "20261006170000" stamp.
--
-- ============================================================================
-- N2S maps through the Automatiq hub (aq_event_map) first, and writes what it
-- maps back into it.
--
-- FOUND (2026-10-06): N2S kept every mapping only on its own order row. A new
-- order for an event an earlier order had already mapped went through the full
-- matcher again, and only on the next pipeline tick (1/min). Over 7 days, 414
-- of 712 orders (58%) were repeat orders for an already-mapped event; their
-- median time to first cover was 65 s vs 87 s for first orders, i.e. the
-- earlier mapping bought almost nothing.
--
-- The hub already knows the events. Over 30 days of mapped N2S orders, looking
-- up aq_event_map by venue (tevo_venue_id) + local date, then requiring the
-- tevo catalogue start minute to equal the order's start minute and the names
-- to be consistent (aq_name_consistent), unique-or-decline:
--   3,334 unique answers: 3,322 agree with the matcher, 12 differ, 6 ambiguous.
-- The 12: 6 are doubleheader day games where the hub picks the event whose
-- start time matches the order (13:05) and the matcher had picked the night
-- game; 5 are one Belmont racing card; 1 is an operator-manual pick over a
-- duplicate catalogue event at the same minute. The "another catalogue event at
-- the same venue + minute" guard below declines that last kind.
--
-- CHANGE
--   1. n2s_aq_hub_writeback() — every event an N2S order mapped to that the hub
--      does not hold yet is inserted (aq_short_event_id 'N2S-<tevo id>',
--      aq_source 'n2s', mirroring tag_evo_only_events' 'EVO-<id>'). Insert only;
--      existing hub rows are never changed.
--   2. n2s_hub_quick_map() — maps unmapped open orders through the hub (rule
--      above), mapped_via 'n2s_aq_hub', and fires their market pulls at once.
--      Runs inside n2s_crm_fetch_direct right after new orders land (every 30 s),
--      so a known event is mapped and pulled the moment its order arrives
--      instead of waiting for the tick.
--   3. n2s_pipeline_tick runs the quick map BEFORE event_mapper_run, so the full
--      matcher only sees orders the hub could not answer, and the write-back
--      right after it. Both function edits are md5-guarded anchored inserts.
-- Reads/writes our own tables only; pulls are the existing GET-only paths.
-- ============================================================================

-- 1. write N2S mappings back to the hub ---------------------------------------
CREATE OR REPLACE FUNCTION public.n2s_aq_hub_writeback()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'n2s_aq_hub_writeback: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.aq_event_map
         (aq_short_event_id, event_name, venue_name, event_date,
          tevo_event_id, tevo_venue_id, tevo_performer_id,
          aq_source, primary_source, imported_at)
  SELECT DISTINCT ON (e.id)
         'N2S-' || e.id, e.name, e.venue_name, left(e.occurs_at_local, 19)::timestamp,
         e.id, e.venue_id, e.primary_performer_id,
         'n2s', 'tevo', now()
    FROM public.n2s_items n
    JOIN public.events e ON e.id = n.tevo_event_id
   WHERE n.tevo_event_id IS NOT NULL
     AND n.n2s_created_at > now() - interval '3 days'
     AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.tevo_event_id = e.id)
   ORDER BY e.id
  ON CONFLICT (aq_short_event_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$function$;

REVOKE ALL ON FUNCTION public.n2s_aq_hub_writeback() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_aq_hub_writeback() TO service_role;
COMMENT ON FUNCTION public.n2s_aq_hub_writeback() IS
  'Inserts into aq_event_map (N2S-<tevo id>, aq_source n2s) every event an N2S order mapped to in the last 3 days that the hub does not hold. Insert-only. Run by n2s_pipeline_tick (20261006170000).';

-- 2. map open orders through the hub, then pull them at once --------------------
CREATE OR REPLACE FUNCTION public.n2s_hub_quick_map(p_only_open boolean DEFAULT true, p_fire boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_mapped int := 0; v_ids bigint[]; v_events bigint[]; v_pull jsonb;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'n2s_hub_quick_map: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;

  WITH todo AS (
    SELECT n.n2s_id, n.event_name, n.event_dt,
           public.cross_source_venue_resolve(n.venue) AS vid,
           to_char(n.event_dt, 'YYYY-MM-DD')           AS day_s,
           to_char(n.event_dt, 'YYYY-MM-DD"T"HH24:MI') AS minute_s
      FROM public.n2s_items n
     WHERE n.tevo_event_id IS NULL AND NOT n.is_terminal
       AND n.event_name IS NOT NULL AND n.event_dt IS NOT NULL AND n.venue IS NOT NULL
       AND (NOT p_only_open
            OR (public.n2s_event_live(n.event_dt, NULL)
                AND public.n2s_timer_open(n.timer_expires_at, n.timer_expired, n.alert_at)))
  ),
  cand AS (
    SELECT t.n2s_id, a.tevo_event_id
      FROM todo t
      JOIN public.aq_event_map a
        ON a.tevo_venue_id = t.vid
       AND a.event_date >= t.event_dt::date AND a.event_date < t.event_dt::date + 1
       AND a.tevo_event_id IS NOT NULL
      JOIN public.events e ON e.id = a.tevo_event_id
     WHERE t.vid IS NOT NULL
       AND left(e.occurs_at_local, 16) = t.minute_s
       AND public.aq_name_consistent(a.event_name, t.event_name)
  ),
  uniq AS (
    SELECT c.n2s_id, min(c.tevo_event_id) AS eid
      FROM cand c GROUP BY c.n2s_id
    HAVING count(DISTINCT c.tevo_event_id) = 1
  ),
  -- decline when the catalogue has another name-consistent event at the same
  -- venue and minute (duplicate listings of one game)
  safe AS (
    SELECT u.n2s_id, u.eid
      FROM uniq u JOIN todo t ON t.n2s_id = u.n2s_id
     WHERE NOT EXISTS (
             SELECT 1 FROM public.events e2
              WHERE e2.venue_id = t.vid AND e2.id <> u.eid
                AND left(e2.occurs_at_local, 10) = t.day_s
                AND left(e2.occurs_at_local, 16) = t.minute_s
                AND public.aq_name_consistent(e2.name, t.event_name))
  ),
  upd AS (
    UPDATE public.n2s_items n
       SET tevo_event_id = s.eid, mapped_via = 'n2s_aq_hub'
      FROM safe s
     WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL
    RETURNING n.n2s_id, n.tevo_event_id
  )
  SELECT count(*)::int, array_agg(n2s_id), array_agg(DISTINCT tevo_event_id)
    INTO v_mapped, v_ids, v_events
    FROM upd;

  IF p_fire AND v_mapped > 0 THEN
    SELECT to_jsonb(p) INTO v_pull FROM public.n2s_pull_events(v_events, interval '2 minutes') p;
    UPDATE public.n2s_items SET sources_pulled_at = now()
     WHERE n2s_id = ANY(v_ids) AND sources_pulled_at IS NULL;
  END IF;

  RETURN jsonb_build_object('mapped', v_mapped,
                            'events', COALESCE(cardinality(v_events), 0),
                            'pull', v_pull);
END
$function$;

REVOKE ALL ON FUNCTION public.n2s_hub_quick_map(boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_hub_quick_map(boolean, boolean) TO service_role;
COMMENT ON FUNCTION public.n2s_hub_quick_map(boolean, boolean) IS
  'Maps unmapped open N2S orders through aq_event_map (venue + local day, start minute from the tevo catalogue, consistent name; unique-or-decline; declines when the catalogue has another such event at that venue/minute), mapped_via n2s_aq_hub, then fires their pulls. Run by n2s_crm_fetch_direct after new orders land and by n2s_pipeline_tick before event_mapper_run (20261006170000).';

-- 3. wire it in -----------------------------------------------------------------
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  -- n2s_crm_fetch_direct: quick map right after new orders are upserted
  v_def := pg_get_functiondef('public.n2s_crm_fetch_direct(integer, integer, integer)'::regprocedure);
  IF md5(v_def) <> '9021df77daa840d0e29b09823592ca8a' THEN
    RAISE EXCEPTION 'n2s_crm_fetch_direct changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  v_new := replace(v_def,
$a$    v_rows := public.n2s_items_upsert(v_body);
  END IF;
$a$,
$b$    v_rows := public.n2s_items_upsert(v_body);
    -- mig 20261006170000: known events map + pull the moment their order lands
    IF v_new > 0 THEN
      BEGIN
        PERFORM public.n2s_hub_quick_map();
      EXCEPTION WHEN OTHERS THEN
        v_err := left(COALESCE(v_err || '; ', '') || 'hub_quick_map: ' || SQLERRM, 300);
      END;
    END IF;
  END IF;
$b$);
  IF v_new = v_def THEN RAISE EXCEPTION 'n2s_crm_fetch_direct: anchor not found'; END IF;
  EXECUTE v_new;

  -- n2s_pipeline_tick: hub before the full matcher, write-back after it
  v_def := pg_get_functiondef('public.n2s_pipeline_tick(integer)'::regprocedure);
  IF md5(v_def) <> 'ee7962814e2fc96bcae227eee8ada372' THEN
    RAISE EXCEPTION 'n2s_pipeline_tick changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  v_new := replace(v_def,
$a$  v_stage := 'event_mapper_run';
$a$,
$b$  -- mig 20261006170000: the Automatiq hub answers known events; the full
  -- matcher below only sees what it could not.
  v_stage := 'hub_quick_map';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      v_out := v_out || jsonb_build_object('hub', public.n2s_hub_quick_map());
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
  END IF;

  v_stage := 'event_mapper_run';
$b$);
  v_new := replace(v_new,
$a$  -- GoTickets name matcher, EVERY tick,$a$,
$b$  v_stage := 'hub_writeback';
  BEGIN
    v_out := v_out || jsonb_build_object('hub_written', public.n2s_aq_hub_writeback());
  EXCEPTION WHEN OTHERS THEN
    v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
  END;

  -- GoTickets name matcher, EVERY tick,$b$);
  IF v_new = v_def OR v_new NOT LIKE '%hub_quick_map%' OR v_new NOT LIKE '%hub_writeback%' THEN
    RAISE EXCEPTION 'n2s_pipeline_tick: anchors not found';
  END IF;
  EXECUTE v_new;
END $mig$;

-- rollback:
--   re-create n2s_crm_fetch_direct and n2s_pipeline_tick without the
--   'mig 20261006170000' blocks; DROP FUNCTION public.n2s_hub_quick_map(boolean, boolean),
--   public.n2s_aq_hub_writeback(). Hub rows with aq_source = 'n2s' and orders with
--   mapped_via = 'n2s_aq_hub' are correct data and are left in place.
