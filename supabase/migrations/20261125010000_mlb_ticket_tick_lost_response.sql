-- Migration 20261125010000 · level:data-collection · lane:A1 (data plane — MLB schedule; this session built the poller, operator 2026-11-16/17) · writes:mlb_ticket_tick(replaced) · reads:net._http_response,mlb_ticket_sync,mlb_ticket_team,mlb_ticket_config · pre:20261117060000
--
-- mlb_ticket_tick NO LONGER STOPS FOR GOOD WHEN AN ANSWER IS LOST.
--
-- What happened (prod, 2026-11-25): the database restarted at 00:26:48 UTC. pg_net keeps its answers in
-- an unlogged table, so a restart empties it. Three club reads fired at 00:23 were still waiting, and
-- their answers were gone. From 00:28 every run of mlb_ticket_tick_1min failed with
--     ERROR: record "r" is not assigned yet
-- and, because the failure undoes the run, the three reads stayed "waiting" and the next run failed the
-- same way: no club was read again. The poller could not recover by itself.
--
-- Why: the answer was read into a record variable (`SELECT ... INTO r`). For a read whose answer is
-- missing after 3 minutes the function set `r := NULL` and then tested `r IS NOT NULL`. A record that
-- has never held a row has no shape, `r := NULL` does not give it one, and testing it raises. It only
-- went unnoticed because a lost answer was nearly always met after another read had already landed in
-- the same run and given `r` its shape (one such failure on 2026-11-24 22:49 UTC cleared by itself).
--
-- NOW: the status and the body are read into two plain variables, which can be null. A lost answer is
-- recorded as before (`last_error` = 'http lost', tries + 1, the read is released and tried again
-- after 30 minutes). Nothing else in the function changes: the rest of the body is 20261117060000's,
-- character for character.
--
-- No table, cron job or grant changes. Applying it is enough to free the three stuck reads: the next
-- run records them as lost and carries on.
--
-- rollback: re-apply mlb_ticket_tick from 20261117060000 (which brings the fault back).

CREATE OR REPLACE FUNCTION public.mlb_ticket_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE
  cfg       public.mlb_ticket_config;
  s         public.mlb_ticket_sync;
  v_status  int;          -- the answer's status and body; both null when the answer is lost
  v_content text;
  j         jsonb;
  v_rows    int;
  v_err     text;
  v_sport   int;
  v_prior   boolean;
  v_landed  int := 0;
  v_errors  int := 0;
  v_waiting int := 0;
  v_fired   int := 0;
  v_now     timestamp := now() AT TIME ZONE 'America/New_York';
  v_year    int := extract(year FROM v_now)::int;
  v_seasons int[];
BEGIN
  SELECT * INTO cfg FROM public.mlb_ticket_config;
  -- seasons that still have games: this one until 31 October, and the next
  v_seasons := CASE WHEN extract(month FROM v_now) >= 11 THEN ARRAY[v_year + 1] ELSE ARRAY[v_year, v_year + 1] END;
  INSERT INTO public.mlb_ticket_sync (team_id, season)
  SELECT t.team_id, y FROM public.mlb_ticket_team t CROSS JOIN unnest(v_seasons) y
   WHERE t.active
  ON CONFLICT DO NOTHING;

  -- 1. land every read whose answer is back
  FOR s IN SELECT * FROM public.mlb_ticket_sync WHERE pending_request_id IS NOT NULL
            ORDER BY pending_since FOR UPDATE SKIP LOCKED
  LOOP
    SELECT x.status_code, x.content INTO v_status, v_content FROM net._http_response x WHERE x.id = s.pending_request_id;
    IF NOT FOUND THEN
      IF s.pending_since > now() - interval '3 minutes' THEN
        v_waiting := v_waiting + 1;
        CONTINUE;
      END IF;
      v_status := NULL;
      v_content := NULL;
    END IF;
    j := CASE WHEN v_content IS NOT NULL THEN public.safe_jsonb(v_content) END;
    IF v_status IS DISTINCT FROM 200 OR j->'events' IS NULL OR j->'events' ? 'error' THEN
      v_err := format('http %s %s', coalesce(v_status::text, 'lost'), left(coalesce(v_content, ''), 200));
      UPDATE public.mlb_ticket_sync
         SET pending_request_id = NULL, tries = tries + 1, last_error = v_err, last_error_at = now()
       WHERE team_id = s.team_id AND season = s.season;
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    SELECT sport_id INTO v_sport FROM public.mlb_ticket_team WHERE team_id = s.team_id;

    -- 1a. games
    WITH items AS (
      SELECT g FROM jsonb_array_elements(
               CASE jsonb_typeof(j->'events'->'game') WHEN 'array' THEN j->'events'->'game'
                    WHEN 'object' THEN jsonb_build_array(j->'events'->'game') ELSE '[]'::jsonb END) g
       WHERE (g->>'schedule_id') ~ '^\d+$'),
    links AS (
      SELECT i.g,
             (SELECT tl FROM jsonb_array_elements(CASE jsonb_typeof(i.g->'ticket_link') WHEN 'array' THEN i.g->'ticket_link'
                                               WHEN 'object' THEN jsonb_build_array(i.g->'ticket_link') ELSE '[]'::jsonb END) tl
               WHERE coalesce(tl->>'tlink', '') <> ''
               ORDER BY (public.mlb_ticket_direct_url(tl->>'tlink') IS NOT NULL) DESC,
                        (upper(coalesce(tl->>'ticket_category', '')) = 'TICKETS') DESC LIMIT 1) AS tl
        FROM items i),
    parsed AS (
      SELECT l.g, l.tl, l.tl->>'tlink' AS raw_link,
             (l.g->>'tbd_flag') = 'Y' AS tbd,
             CASE WHEN l.g->>'game_date' ~ '^\d{4}-\d\d-\d\d$' THEN (l.g->>'game_date')::date END AS gdate,
             CASE WHEN l.g->>'game_time_local' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (l.g->>'game_time_local')::timestamp END AS tlocal,
             CASE WHEN l.g->>'game_time' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                  THEN to_timestamp(l.g->>'game_time', 'YYYYMMDD HH12:MI:SS AM')::timestamp AT TIME ZONE 'UTC' END AS tutc
        FROM links l)
    INSERT INTO public.mlb_ticket_game AS t (
      schedule_id, mlb_game_id, season, sport_id, game_type, game_type_name, game_date, game_time_local, time_zone_local,
      game_time_utc, is_tbd, game_number, if_necessary, status, descr, home_team_id, home_name, home_abbrev,
      away_team_id, away_name, away_abbrev, venue_id, venue_name, venue_city, venue_postal_code,
      ticket_link_raw, ticket_url, ticket_url_kind, on_sale_start, on_sale_end, raw, last_seen_at, changed_at)
    SELECT (p.g->>'schedule_id')::bigint, p.g->>'game_id',
           coalesce(extract(year FROM p.gdate)::int, s.season), coalesce(v_sport, 1),
           p.g->>'game_type', p.g->>'gt_name_short',
           p.gdate, p.tlocal, p.g->>'time_zone_local', p.tutc, p.tbd,
           CASE WHEN p.g->>'game_number' ~ '^\d+$' THEN (p.g->>'game_number')::int END,
           (p.g->>'if_necessary') = 'Y', p.g->>'status', nullif(p.g->>'descr', ''),
           CASE WHEN p.g->>'home_team_id' ~ '^\d+$' THEN (p.g->>'home_team_id')::int END,
           p.g->>'home_name_full', p.g->>'home_name_abbrev',
           CASE WHEN p.g->>'away_team_id' ~ '^\d+$' THEN (p.g->>'away_team_id')::int END,
           p.g->>'away_name_full', p.g->>'away_name_abbrev',
           CASE WHEN p.g->>'venue_id' ~ '^\d+$' THEN (p.g->>'venue_id')::int END,
           p.g->>'venue_name', p.g->>'venue_city', p.g->>'venue_postal_code',
           p.raw_link, public.mlb_ticket_direct_url(p.raw_link),
           CASE WHEN p.raw_link IS NULL THEN NULL
                WHEN public.mlb_ticket_direct_url(p.raw_link) IS NOT NULL THEN 'direct' ELSE 'redirect' END,
           CASE WHEN p.tl->>'on_sale_start_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.tl->>'on_sale_start_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
           CASE WHEN p.tl->>'on_sale_end_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.tl->>'on_sale_end_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
           p.g - 'promotion', now(), now()
      FROM parsed p
    ON CONFLICT (schedule_id) DO UPDATE SET
      mlb_game_id = EXCLUDED.mlb_game_id, season = EXCLUDED.season, sport_id = EXCLUDED.sport_id,
      game_type = EXCLUDED.game_type,
      game_type_name = EXCLUDED.game_type_name, game_date = EXCLUDED.game_date,
      game_time_local = EXCLUDED.game_time_local, time_zone_local = EXCLUDED.time_zone_local,
      game_time_utc = EXCLUDED.game_time_utc, is_tbd = EXCLUDED.is_tbd, game_number = EXCLUDED.game_number,
      if_necessary = EXCLUDED.if_necessary, status = EXCLUDED.status, descr = EXCLUDED.descr,
      home_team_id = EXCLUDED.home_team_id, home_name = EXCLUDED.home_name, home_abbrev = EXCLUDED.home_abbrev,
      away_team_id = EXCLUDED.away_team_id, away_name = EXCLUDED.away_name, away_abbrev = EXCLUDED.away_abbrev,
      venue_id = EXCLUDED.venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city,
      venue_postal_code = EXCLUDED.venue_postal_code,
      ticket_link_raw = EXCLUDED.ticket_link_raw, ticket_url = EXCLUDED.ticket_url, ticket_url_kind = EXCLUDED.ticket_url_kind,
      on_sale_start = EXCLUDED.on_sale_start, on_sale_end = EXCLUDED.on_sale_end, raw = EXCLUDED.raw,
      last_seen_at = now(), removed_at = NULL,
      changed_at = CASE WHEN (t.game_date, t.game_time_local, t.game_time_utc, t.is_tbd, t.game_number, t.status,
                              t.home_team_id, t.away_team_id, t.venue_id, t.ticket_url, t.on_sale_start, t.game_type)
                             IS DISTINCT FROM
                             (EXCLUDED.game_date, EXCLUDED.game_time_local, EXCLUDED.game_time_utc, EXCLUDED.is_tbd,
                              EXCLUDED.game_number, EXCLUDED.status, EXCLUDED.home_team_id, EXCLUDED.away_team_id,
                              EXCLUDED.venue_id, EXCLUDED.ticket_url, EXCLUDED.on_sale_start, EXCLUDED.game_type)
                             OR t.removed_at IS NOT NULL
                        THEN now() ELSE t.changed_at END,
      tevo_event_id     = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_event_id END,
      tevo_matched_at   = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_matched_at END,
      tevo_match_method = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_match_method END;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows > 0 THEN
      -- games of this club and season the schedule no longer lists
      UPDATE public.mlb_ticket_game g SET removed_at = now(), changed_at = now()
       WHERE g.home_team_id = s.team_id AND g.season = s.season AND g.removed_at IS NULL
         AND g.last_seen_at < now() AND g.game_date >= current_date;

      -- 1b. promotions (a club's first load is not news)
      v_prior := EXISTS (SELECT 1 FROM public.mlb_ticket_promotion p JOIN public.mlb_ticket_game g USING (schedule_id)
                          WHERE g.home_team_id = s.team_id);
      WITH promos AS (
        SELECT (g->>'schedule_id')::bigint AS sid, pr
          FROM jsonb_array_elements(
                 CASE jsonb_typeof(j->'events'->'game') WHEN 'array' THEN j->'events'->'game'
                      WHEN 'object' THEN jsonb_build_array(j->'events'->'game') ELSE '[]'::jsonb END) g,
               jsonb_array_elements(CASE jsonb_typeof(g->'promotion') WHEN 'array' THEN g->'promotion'
                                         WHEN 'object' THEN jsonb_build_array(g->'promotion') ELSE '[]'::jsonb END) pr
         WHERE (g->>'schedule_id') ~ '^\d+$' AND coalesce(pr->>'offer_id', '') <> ''),
      up AS (
        INSERT INTO public.mlb_ticket_promotion AS t (
          schedule_id, offer_id, offer_type, promotion_types, offer_name, description, presented_by,
          distribution, link_url, info_url, image_url)
        SELECT DISTINCT ON (sid, pr->>'offer_id')
               sid, pr->>'offer_id', nullif(pr->>'offer_type', ''), nullif(pr->>'promotion_types', ''),
               nullif(pr->>'offer_name', ''), nullif(pr->>'description', ''), nullif(pr->>'presented_by', ''),
               nullif(pr->>'distribution', ''), nullif(pr->>'tlink', ''), nullif(pr->>'alt_page_url', ''),
               nullif(nullif(pr->>'image_url', ''), 'undefined')
          FROM promos
        ON CONFLICT (schedule_id, offer_id) DO UPDATE SET
          offer_type = EXCLUDED.offer_type, promotion_types = EXCLUDED.promotion_types,
          offer_name = EXCLUDED.offer_name, description = EXCLUDED.description,
          presented_by = EXCLUDED.presented_by, distribution = EXCLUDED.distribution,
          link_url = EXCLUDED.link_url, info_url = EXCLUDED.info_url, image_url = EXCLUDED.image_url,
          last_seen_at = now(), removed_at = NULL
        RETURNING t.schedule_id, t.offer_type, t.offer_name, (xmax = 0) AS inserted)
      INSERT INTO public.mlb_ticket_change (entity, schedule_id, kind, new_value, notable)
      SELECT 'promotion', up.schedule_id, 'promo_added',
             coalesce(up.offer_type || ': ', '') || coalesce(up.offer_name, ''),
             v_prior AND up.offer_type IN ('Giveaway', 'Theme Days')
        FROM up WHERE up.inserted;

      UPDATE public.mlb_ticket_promotion p SET removed_at = now()
        FROM public.mlb_ticket_game g
       WHERE g.schedule_id = p.schedule_id AND g.home_team_id = s.team_id AND g.season = s.season
         AND p.removed_at IS NULL AND p.last_seen_at < now();
    END IF;

    -- 1c. stadium live events: non_game types O and A, without parking / tours / rentals / extras
    WITH ng AS (
      SELECT x FROM jsonb_array_elements(
               CASE jsonb_typeof(j->'events'->'non_game') WHEN 'array' THEN j->'events'->'non_game'
                    WHEN 'object' THEN jsonb_build_array(j->'events'->'non_game') ELSE '[]'::jsonb END) x
       WHERE (x->>'schedule_id') ~ '^\d+$'
         AND x->>'event_type' IN ('O', 'A')
         AND coalesce(x->>'title', '') !~* '\m(parking|tours?|rentals?|wheelchair|batting practice|gameday experience|vip day|premium seating|tbd at tbd|clinic|camp)\M'),
    p AS (
      SELECT x,
             (SELECT tl->>'tlink' FROM jsonb_array_elements(CASE jsonb_typeof(x->'ticket_link') WHEN 'array' THEN x->'ticket_link'
                                       WHEN 'object' THEN jsonb_build_array(x->'ticket_link') ELSE '[]'::jsonb END) tl
               WHERE coalesce(tl->>'tlink', '') <> '' LIMIT 1) AS raw_link,
             CASE WHEN x->>'event_time_local' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (x->>'event_time_local')::timestamp END AS tlocal,
             CASE WHEN x->>'event_time' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (x->>'event_time')::timestamp AT TIME ZONE 'UTC' END AS tutc
        FROM ng)
    INSERT INTO public.mlb_ticket_event AS t (
      schedule_id, team_id, sport_id, season, event_type, title, descr, event_date, event_time_local,
      time_zone_local, event_time_utc, is_tbd, multi_day, venue_id, venue_name, venue_city, venue_postal_code,
      ticket_link_raw, ticket_url, raw, last_seen_at, changed_at)
    SELECT (p.x->>'schedule_id')::bigint, s.team_id, coalesce(v_sport, 1), coalesce(extract(year FROM p.tlocal)::int, s.season),
           p.x->>'event_type', nullif(p.x->>'title', ''), nullif(p.x->>'descr', ''), p.tlocal::date, p.tlocal,
           p.x->>'time_zone_local', p.tutc, (p.x->>'tbd_flag') = 'Y', (p.x->>'multi_day_switch') = 'Y',
           CASE WHEN p.x->>'venue_id' ~ '^\d+$' THEN (p.x->>'venue_id')::int END,
           p.x->>'venue_name', p.x->>'venue_city', p.x->>'venue_postal_code',
           p.raw_link, public.mlb_ticket_direct_url(p.raw_link), p.x, now(), now()
      FROM p
    ON CONFLICT (schedule_id) DO UPDATE SET
      event_type = EXCLUDED.event_type, title = EXCLUDED.title, descr = EXCLUDED.descr,
      event_date = EXCLUDED.event_date, event_time_local = EXCLUDED.event_time_local,
      time_zone_local = EXCLUDED.time_zone_local, event_time_utc = EXCLUDED.event_time_utc,
      is_tbd = EXCLUDED.is_tbd, multi_day = EXCLUDED.multi_day, venue_id = EXCLUDED.venue_id,
      venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city, venue_postal_code = EXCLUDED.venue_postal_code,
      ticket_link_raw = EXCLUDED.ticket_link_raw, ticket_url = EXCLUDED.ticket_url, raw = EXCLUDED.raw,
      last_seen_at = now(), removed_at = NULL,
      changed_at = CASE WHEN (t.event_date, t.event_time_local, t.title, t.ticket_url, t.venue_id)
                             IS DISTINCT FROM (EXCLUDED.event_date, EXCLUDED.event_time_local, EXCLUDED.title,
                                               EXCLUDED.ticket_url, EXCLUDED.venue_id)
                        THEN now() ELSE t.changed_at END,
      tevo_event_id = CASE WHEN t.event_date IS DISTINCT FROM EXCLUDED.event_date THEN NULL ELSE t.tevo_event_id END;

    IF v_rows > 0 THEN
      UPDATE public.mlb_ticket_event ev SET removed_at = now(), changed_at = now()
       WHERE ev.team_id = s.team_id AND ev.season = s.season AND ev.removed_at IS NULL
         AND ev.last_seen_at < now() AND ev.event_date >= current_date;
    END IF;

    UPDATE public.mlb_ticket_sync
       SET pending_request_id = NULL, tries = 0, last_ok_at = now(), last_games = v_rows, last_error = NULL
     WHERE team_id = s.team_id AND season = s.season;
    PERFORM public.mlb_ticket_match(NULL, s.team_id);
    PERFORM public.mlb_ticket_match_events(s.team_id);
    v_landed := v_landed + 1;
  END LOOP;

  -- once an hour: every upcoming game and stadium event, for EVO / SeatGeek events created since
  IF extract(minute FROM now()) = 30 THEN
    PERFORM public.mlb_ticket_match(NULL, NULL);
    PERFORM public.mlb_ticket_match_events(NULL);
  END IF;

  -- 2. fire the due reads: MLB clubs every mlb_refresh, minor league clubs every milb_refresh
  FOR s IN
    SELECT y.* FROM public.mlb_ticket_sync y JOIN public.mlb_ticket_team t USING (team_id)
     WHERE y.season = ANY (v_seasons) AND y.pending_request_id IS NULL
       AND (y.last_ok_at IS NULL
            OR y.last_ok_at < now() - CASE WHEN t.sport_id = 1 THEN cfg.mlb_refresh ELSE cfg.milb_refresh END)
       AND (y.last_error_at IS NULL OR y.last_error_at < now() - interval '30 minutes' OR y.last_ok_at > y.last_error_at)
     ORDER BY y.last_ok_at NULLS FIRST, (t.sport_id <> 1), y.team_id, y.season
     LIMIT coalesce(cfg.fires_per_tick, 3)
     FOR UPDATE OF y SKIP LOCKED
  LOOP
    PERFORM public.mlb_ticket_fire(s.team_id, s.season);
    v_fired := v_fired + 1;
  END LOOP;

  RETURN jsonb_build_object('landed', v_landed, 'errors', v_errors, 'waiting', v_waiting, 'fired', v_fired);
END $function$;

REVOKE ALL ON FUNCTION public.mlb_ticket_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_ticket_tick() TO service_role;
