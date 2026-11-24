-- Migration 20261123183730 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:primary_poll_event(+announced_at),primary_poll_listing(delete),primary_poll_run_done()(replaced),bot_chat(via bot_chat_log) · reads:primary_poll_source · pre:20261123171030
-- Already applied to prod · via MCP 2026-11-23 (operator: "apply and merge"); re-apply is a no-op.
--
-- THE BOX-OFFICE POLL: OLD LISTINGS ARE CLEANED UP, AND NEW EVENTS ANNOUNCE THEMSELVES TO THE EVENT MAPPER.
-- Operator 2026-11-23: "add the cleanup for old listings, also ping and map lynx when schedule releases".
--
-- 1. CLEANUP. An event's listings are replaced each time the event is polled. But an event the box office no
--    longer lists (a game that has been played) is never polled again, so its last listings stayed in
--    primary_poll_listing: never sent (the feeds serve the newest pull only), but 350 to 850 rows a game, for
--    ever. primary_poll_run_done() now deletes, when a pull closes, the listings of every event of that source
--    the pull did not list. The event row itself is kept, with its EVO match.
--
-- 2. ANNOUNCE. When a pull closes, the events it listed that have not been announced and have no EVO event yet
--    are posted once to the mapping thread (bot_chat, a flag in reply to 6851, the mapping owner's thread), at
--    most 80 a post, and marked announced. So when a source's schedule is released (the Minnesota Lynx, source
--    'lynx', read by the browser worker from tickets.lynxbasketball.com as soon as it lists games) the mapper
--    is told without anyone watching. The 42 events already there were announced by hand (bot_chat 7244) and
--    are marked so here. A post that fails leaves the events unannounced, so the next pull tries again; it
--    never fails the pull.
--
-- Nothing here calls a source (RULE 2), and no mapper function or mapping cron is touched: this only posts.
--
-- rollback: re-apply primary_poll_run_done() from 20261123171030;
--           ALTER TABLE public.primary_poll_event DROP COLUMN announced_at;

ALTER TABLE public.primary_poll_event ADD COLUMN IF NOT EXISTS announced_at timestamptz;
UPDATE public.primary_poll_event SET announced_at = now() WHERE announced_at IS NULL;

CREATE OR REPLACE FUNCTION public.primary_poll_run_done(p_source text, p_run text, p_event_ids jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_n integer; v_new integer; v_ids text[]; v_lines text;
BEGIN
  IF coalesce(p_source, '') = '' OR coalesce(p_run, '') = '' OR jsonb_typeof(p_event_ids) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'primary_poll_run_done: a source, a run and an array of event ids are required';
  END IF;
  UPDATE public.primary_poll_event t SET last_run = p_run
   WHERE t.source = p_source
     AND t.source_event_id IN (SELECT jsonb_array_elements_text(p_event_ids));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO public.primary_poll_source AS s (source, current_run, finished_at, events)
  VALUES (p_source, p_run, now(), v_n)
  ON CONFLICT (source) DO UPDATE SET current_run = EXCLUDED.current_run, finished_at = now(), events = EXCLUDED.events;

  -- 1. the listings of the events this pull did not list: the box office no longer has them
  DELETE FROM public.primary_poll_listing l
   USING public.primary_poll_event t
   WHERE l.source = p_source AND t.source = l.source AND t.source_event_id = l.source_event_id
     AND t.last_run IS DISTINCT FROM p_run;

  -- 2. events new to us, for the event mapper: one post, and only then marked announced
  SELECT array_agg(x.source_event_id), count(*)::integer,
         string_agg(format('  %s | %s %s | %s', x.source_event_id, coalesce(x.event_date::text, 'no date'),
                           coalesce(to_char(x.start_local_time, 'HH24:MI'), ''), x.name), E'\n')
    INTO v_ids, v_new, v_lines
    FROM (SELECT t.source_event_id, t.event_date, t.start_local_time, t.name
            FROM public.primary_poll_event t
           WHERE t.source = p_source AND t.last_run = p_run AND t.announced_at IS NULL AND t.tevo_event_id IS NULL
           ORDER BY t.event_date NULLS LAST, t.start_local_time NULLS LAST, t.source_event_id
           LIMIT 80) x;
  IF v_new > 0 THEN
    BEGIN
      PERFORM public.bot_chat_log(
        p_level := 'data-collection', p_lane := 'A1', p_event_type := 'flag',
        p_message := format(E'NEW PRIMARY EVENTS TO MAP (posted by primary_poll_run_done): %s new event(s) from the box-office poll, source ''%s'', in primary_poll_event with no tevo_event_id. Venue: %s. id | local start | name:\n%s',
                            v_new, p_source,
                            (SELECT coalesce(string_agg(DISTINCT concat_ws(', ', t.venue_name, t.venue_city, t.venue_state), ' / '), 'unknown')
                               FROM public.primary_poll_event t
                              WHERE t.source = p_source AND t.source_event_id = ANY (v_ids)),
                            v_lines),
        p_related_mig := '20261123183730', p_in_reply_to := 6851,
        p_meta := jsonb_build_object('source', p_source, 'events', v_new, 'event_ids', to_jsonb(v_ids)));
      UPDATE public.primary_poll_event t SET announced_at = now()
       WHERE t.source = p_source AND t.source_event_id = ANY (v_ids);
    EXCEPTION WHEN OTHERS THEN
      -- the post is a courtesy to the mapper: it must never fail a pull. Unannounced events are tried again
      -- when the next pull closes.
      RAISE WARNING 'primary_poll_run_done: new events of % not announced: %', p_source, SQLERRM;
    END;
  END IF;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.primary_poll_run_done(text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_run_done(text, text, jsonb) TO service_role;
