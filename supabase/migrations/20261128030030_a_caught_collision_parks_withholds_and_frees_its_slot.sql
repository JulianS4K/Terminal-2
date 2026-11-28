-- A caught collision parks the event, withholds its listings, and frees its slot.
--
-- Operator 2026-11-28: "if an event sends wrong info and is caught add it to the once a day
-- poller and stop sending listings to crm but monitor, then replace with a new one."
--
-- Each of the three clauses maps to one thing here:
--   once a day poller  -> cadence_pinned + poll_interval = no_tickets_every (the parked band)
--   stop sending       -> collision_paused is withheld in the events feed as
--                         'wrong_performance' and excluded from the listings feed, and the
--                         capture is deleted so nothing stale lingers
--   but monitor        -> watch stays TRUE, so it is still read once a day and still visible
--   replace with a new -> a parked event does not hold a place against target_events
--                         (mig 20261126230000), so axs_watch_fill hands the slot to another
--
-- WHEN IT FIRES. Both conditions must hold:
--   (a) another watched AXS event already carries the same axs_event_internal, and
--   (b) THIS body's own event block disagrees with its onsale sub_event, on the TIME
--       (axs_watch_wrong_performance) or on the SHOW NAME (axs_watch_wrong_show)
-- (b) is what decides WHICH of the two is wrong, and it is the behaviour both proven cases
-- showed: the correct event's time agrees with the onsale it was served and the detector
-- stays silent on it, while the impostor's disagrees. Requiring (a) as well is what keeps the
-- known false positives out -- PBR 1583731 trips (b) but shares its internal id with nothing,
-- so it is left alone. If two events collide and NEITHER disagrees, we cannot tell which is
-- wrong from the data, so nothing is parked and v_axs_event_collisions surfaces it for the
-- operator. Deliberately: a wrong park costs real inventory, as the Red Rocks episode showed.

BEGIN;

-- 1. the settle records the id and acts on a catch -------------------------------------
DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
  decl_old CONSTANT text := '  v_perf text; v_nontrans boolean := false;';
  decl_new CONSTANT text := '  v_perf text; v_nontrans boolean := false;' || E'\n' ||
                            '  v_internal text; v_collides boolean := false;';
  set_old  CONSTANT text := '    v_nontrans := public.axs_watch_non_transferable(body);';
  set_new  CONSTANT text := '    v_nontrans := public.axs_watch_non_transferable(body);' || E'\n' ||
                            '    v_internal := public.axs_watch_internal_event_id(body);';
  -- the cadence update must not undo a collision park: cadence_pinned is recomputed here
  cad_old  CONSTANT text := '     WHERE e.source = ''axs'' AND e.source_event_id = p_event_id;' || E'\n' || E'\n' ||
                            '    -- An event that says it is not on sale keeps its own, slower rule';
  cad_new  CONSTANT text := '     WHERE e.source = ''axs'' AND e.source_event_id = p_event_id' || E'\n' ||
                            '       -- mig 20261128030030: never recompute the band of a collision-parked event' || E'\n' ||
                            '       AND NOT coalesce(e.collision_paused, false);' || E'\n' || E'\n' ||
                            '    -- An event that says it is not on sale keeps its own, slower rule';
  act_old  CONSTANT text := '  IF p_status_code = 200 AND coalesce(p_charge, true) THEN';
  act_new  CONSTANT text :=
    '  -- mig 20261128030030: remember AXS''''s own event id, and act when two of ours share one.' || E'\n' ||
    '  IF v_internal IS NOT NULL THEN' || E'\n' ||
    '    UPDATE public.primary_poll_event e SET axs_event_internal = v_internal' || E'\n' ||
    '     WHERE e.source = ''axs'' AND e.source_event_id = p_event_id' || E'\n' ||
    '       AND e.axs_event_internal IS DISTINCT FROM v_internal;' || E'\n' ||
    '    SELECT EXISTS (SELECT 1 FROM public.primary_poll_event o' || E'\n' ||
    '                    WHERE o.source = ''axs'' AND o.axs_event_internal = v_internal' || E'\n' ||
    '                      AND o.source_event_id <> p_event_id AND o.watch)' || E'\n' ||
    '      INTO v_collides;' || E'\n' ||
    '  END IF;' || E'\n' ||
    '  -- parked, withheld, still watched, and its place goes back to the fill' || E'\n' ||
    '  IF v_collides AND (v_perf IS NOT NULL OR public.axs_watch_wrong_show(body)) THEN' || E'\n' ||
    '    DELETE FROM public.primary_poll_listing_piece pc' || E'\n' ||
    '     WHERE pc.source = ''axs'' AND pc.source_event_id = p_event_id;' || E'\n' ||
    '    DELETE FROM public.primary_poll_listing l' || E'\n' ||
    '     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;' || E'\n' ||
    '    UPDATE public.primary_poll_event e' || E'\n' ||
    '       SET collision_paused = true, cadence_pinned = true,' || E'\n' ||
    '           poll_interval = v_cfg.no_tickets_every,' || E'\n' ||
    '           next_poll_at  = now() + v_cfg.no_tickets_every,' || E'\n' ||
    '           listing_count = 0, listed_quantity = 0, median_price = NULL,' || E'\n' ||
    '           total_available = 0, price_min = NULL, price_max = NULL' || E'\n' ||
    '     WHERE e.source = ''axs'' AND e.source_event_id = p_event_id;' || E'\n' ||
    '    IF NOT EXISTS (SELECT 1 FROM public.axs_watch_audit a' || E'\n' ||
    '                    WHERE a.action = ''collision'' AND a.axs_event_id = p_event_id) THEN' || E'\n' ||
    '      INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)' || E'\n' ||
    '      VALUES (gen_random_uuid(), ''collision'', p_event_id,' || E'\n' ||
    '              nullif(body->''event''->''venue''->>''name'', ''''),' || E'\n' ||
    '              left(''parked: serves AXS internal event '' || coalesce(v_internal,''?'') ||' || E'\n' ||
    '                   '', which another watched event also serves. '' || coalesce(v_perf,''''), 400));' || E'\n' ||
    '    END IF;' || E'\n' ||
    '  END IF;' || E'\n' ||
    '  IF p_status_code = 200 AND coalesce(p_charge, true) THEN';
  n int;
BEGIN
  IF position('axs_watch_internal_event_id' in src) > 0 THEN
    RAISE NOTICE 'the settle already records the internal id; nothing to do';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, decl_old, ''))) / length(decl_old);
  IF n <> 1 THEN RAISE EXCEPTION 'settle declare anchor matched % times, expected 1', n; END IF;
  n := (length(src) - length(replace(src, set_old, ''))) / length(set_old);
  IF n <> 1 THEN RAISE EXCEPTION 'settle detector-call anchor matched % times, expected 1', n; END IF;
  n := (length(src) - length(replace(src, cad_old, ''))) / length(cad_old);
  IF n <> 1 THEN RAISE EXCEPTION 'settle cadence anchor matched % times, expected 1', n; END IF;
  n := (length(src) - length(replace(src, act_old, ''))) / length(act_old);
  IF n <> 1 THEN RAISE EXCEPTION 'settle charge anchor matched % times, expected 1', n; END IF;
  src := replace(src, decl_old, decl_new);
  src := replace(src, set_old,  set_new);
  src := replace(src, cad_old,  cad_new);
  src := replace(src, act_old,  act_new);
  EXECUTE src;
END $surgery$;

-- 2. the audit may say 'collision' ---------------------------------------------------------
ALTER TABLE public.axs_watch_audit DROP CONSTRAINT axs_watch_audit_action_check;
ALTER TABLE public.axs_watch_audit ADD CONSTRAINT axs_watch_audit_action_check
  CHECK (action = ANY (ARRAY['add','retire','short','wrong_performance','non_transferable','collision']));

-- 3. the feeds honour it --------------------------------------------------------------------
DO $surgery$
DECLARE
  v_ev text; v_li text; v_ev_opts text[]; v_li_opts text[]; v_new text; n int;
  -- ahead of not_polled AND thin_inventory: the settle zeroes the listings when it parks, so
  -- a later arm would otherwise claim the row and the CRM would read 'thin_inventory' for an
  -- event that is actually serving someone else's seats. Caught by s36.
  arm_old CONSTANT text := E'            WHEN (t.poll_status = \'pending\'::text) THEN \'not_polled\'::text\n';
  arm_new CONSTANT text := E'            WHEN COALESCE(t.collision_paused, false) THEN \'wrong_performance\'::text\n'
                        || E'            WHEN (t.poll_status = \'pending\'::text) THEN \'not_polled\'::text\n';
  where_old CONSTANT text := '(NOT COALESCE(t.non_transferable, false)) AND ((t.event_date IS NULL) OR (t.event_date >= (CURRENT_DATE - 1)))';
  where_new CONSTANT text := '(NOT COALESCE(t.non_transferable, false)) AND (NOT COALESCE(t.collision_paused, false)) AND ((t.event_date IS NULL) OR (t.event_date >= (CURRENT_DATE - 1)))';
BEGIN
  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass)   INTO v_ev;
  SELECT pg_get_viewdef('v_primary_poll_listings_feed'::regclass) INTO v_li;
  SELECT reloptions INTO v_ev_opts FROM pg_class WHERE relname = 'v_primary_poll_events_feed';
  SELECT reloptions INTO v_li_opts FROM pg_class WHERE relname = 'v_primary_poll_listings_feed';
  IF v_ev ~ 'collision_paused' THEN
    RAISE NOTICE 'the feeds already honour collision_paused; nothing to do';
    RETURN;
  END IF;

  n := (length(v_ev) - length(replace(v_ev, arm_old, ''))) / length(arm_old);
  IF n <> 1 THEN RAISE EXCEPTION 'events feed: the not_polled arm matched % times, expected 1', n; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_events_feed AS ' || replace(v_ev, arm_old, arm_new);
  IF v_ev_opts @> ARRAY['security_invoker=true'] THEN
    EXECUTE 'ALTER VIEW public.v_primary_poll_events_feed SET (security_invoker = true)';
  END IF;

  n := (length(v_li) - length(replace(v_li, where_old, ''))) / length(where_old);
  IF n <> 1 THEN RAISE EXCEPTION 'listings feed: the where anchor matched % times, expected 1', n; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_listings_feed AS ' || replace(v_li, where_old, where_new);
  IF v_li_opts @> ARRAY['security_invoker=true'] THEN
    EXECUTE 'ALTER VIEW public.v_primary_poll_listings_feed SET (security_invoker = true)';
  END IF;

  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass)   INTO v_ev;
  SELECT pg_get_viewdef('v_primary_poll_listings_feed'::regclass) INTO v_li;
  IF v_ev !~ 'collision_paused' OR v_li !~ 'collision_paused' THEN
    RAISE EXCEPTION 'read-back: a feed does not honour collision_paused';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'v_primary_poll_events_feed'
                   AND reloptions @> ARRAY['security_invoker=true']) THEN
    RAISE EXCEPTION 'read-back: the events feed lost security_invoker=true';
  END IF;
  IF (SELECT reloptions FROM pg_class WHERE relname = 'v_primary_poll_listings_feed')
       IS DISTINCT FROM v_li_opts THEN
    RAISE EXCEPTION 'read-back: the listings feed reloptions changed';
  END IF;
END $surgery$;

-- 4. read back ------------------------------------------------------------------------------
DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
BEGIN
  IF position('axs_watch_internal_event_id' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the settle does not record the internal id';
  END IF;
  IF position('collision_paused = true, cadence_pinned = true' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the settle does not park on a collision';
  END IF;
  IF position('AND NOT coalesce(e.collision_paused, false);' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the cadence update can still undo a collision park';
  END IF;
  -- the id reader
  IF public.axs_watch_internal_event_id(jsonb_build_object(
       'onsale', jsonb_build_object('flags', jsonb_build_object('events', jsonb_build_array('5263'))))) <> '5263' THEN
    RAISE EXCEPTION 'the onsale flags path does not read the internal id';
  END IF;
  IF public.axs_watch_internal_event_id(jsonb_build_object(
       'listings', jsonb_build_array(jsonb_build_object('event_id','17673')))) <> '17673' THEN
    RAISE EXCEPTION 'the listings path does not read the internal id';
  END IF;
  IF public.axs_watch_internal_event_id('{}'::jsonb) IS NOT NULL THEN
    RAISE EXCEPTION 'an empty body must yield no internal id';
  END IF;
  -- the audit may say collision
  INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
  VALUES (gen_random_uuid(), 'collision', '__selftest3__', NULL, 'self-test');
  DELETE FROM public.axs_watch_audit WHERE axs_event_id = '__selftest3__';
END $verify$;

COMMIT;
